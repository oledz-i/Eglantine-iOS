// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "core/file_sys/nup_container.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <fmt/ranges.h>
#include <list>
#include <map>
#include <unordered_map>

#include <openssl/evp.h>
#include <zstd.h>

#include "common/logging.h"
#include "common/swap.h"
#include "core/file_sys/vfs/vfs_offset.h"

namespace FileSys {
namespace {

constexpr u32 NoDir = 0xFFFFFFFF;
constexpr std::size_t SuperblockSize = 0x80;
constexpr std::size_t PackageRecordSize = 0x40;
constexpr std::size_t DirRecordSize = 0x18;
constexpr std::size_t FileRecordSize = 0x50;
constexpr std::size_t TocHeaderSize = 0x30;
constexpr std::size_t TlvHeaderSize = 0x8;
constexpr u32 TocMagic = 0x01434F54; // "TOC\x01" little-endian
constexpr u8 CodecRaw = 0;
constexpr u8 CodecZstd = 1;
constexpr u8 PackageFlagStandaloneUpdate = 0x01;

#pragma pack(push, 1)
struct Superblock {
    std::array<u8, 4> magic;
    u16_le header_size;
    u16_le header_version;
    u64_le toc_offset;
    u64_le toc_size;
    std::array<u8, 0x20> toc_sha256;
    u64_le blob_offset;
    u64_le file_size;
    u32_le package_count;
    u32_le flags;
    std::array<u8, 0x10> uuid;
    std::array<u8, 0x20> reserved;
};
static_assert(sizeof(Superblock) == SuperblockSize);

struct TocHeader {
    u32_le magic;
    u32_le package_count;
    u64_le dir_count;
    u64_le file_count;
    u64_le pool_offset;
    u64_le pool_size;
    u64_le reserved;
};
static_assert(sizeof(TocHeader) == TocHeaderSize);

struct PackageRecord {
    u64_le title_id; // 0x00
    u32_le root_dir; // 0x08
    u32_le exefs_dir; // 0x0C
    u32_le romfs_dir; // 0x10
    u32_le version; // 0x14
    u8 kind; // 0x18
    u8 flags; // 0x19
    u16_le reserved; // 0x1A
    u32_le reserved2; // 0x1C
    u64_le meta_offset; // 0x20
    u32_le meta_size; // 0x28
    std::array<u8, 20> reserved3; // 0x2C
};
static_assert(sizeof(PackageRecord) == PackageRecordSize);
static_assert(offsetof(PackageRecord, title_id) == 0x00);
static_assert(offsetof(PackageRecord, root_dir) == 0x08);
static_assert(offsetof(PackageRecord, exefs_dir) == 0x0C);
static_assert(offsetof(PackageRecord, romfs_dir) == 0x10);
static_assert(offsetof(PackageRecord, version) == 0x14);
static_assert(offsetof(PackageRecord, kind) == 0x18);
static_assert(offsetof(PackageRecord, flags) == 0x19);
static_assert(offsetof(PackageRecord, reserved) == 0x1A);
static_assert(offsetof(PackageRecord, reserved2) == 0x1C);
static_assert(offsetof(PackageRecord, meta_offset) == 0x20);
static_assert(offsetof(PackageRecord, meta_size) == 0x28);

struct DirRecord {
    u32_le name_offset;
    u32_le name_length;
    u32_le first_child;
    u32_le child_count;
    u64_le reserved;
};
static_assert(sizeof(DirRecord) == DirRecordSize);

struct FileRecord {
    u32_le name_offset; // 0x00
    u32_le name_length; // 0x04
    u64_le size; // 0x08
    u64_le extent_offset; // 0x10
    u64_le extent_size; // 0x18
    std::array<u8, 0x20> sha256; // 0x20
    u8 codec; // 0x40
    u8 codec_flags; // 0x41
    u16_le reserved2; // 0x42
    std::array<u8, 12> reserved3; // 0x44
};
static_assert(sizeof(FileRecord) == FileRecordSize);
static_assert(offsetof(FileRecord, name_offset) == 0x00);
static_assert(offsetof(FileRecord, name_length) == 0x04);
static_assert(offsetof(FileRecord, size) == 0x08);
static_assert(offsetof(FileRecord, extent_offset) == 0x10);
static_assert(offsetof(FileRecord, extent_size) == 0x18);
static_assert(offsetof(FileRecord, sha256) == 0x20);
static_assert(offsetof(FileRecord, codec) == 0x40);
static_assert(offsetof(FileRecord, codec_flags) == 0x41);
static_assert(offsetof(FileRecord, reserved2) == 0x42);

struct TlvHeader {
    u16_le type;
    u16_le reserved;
    u32_le size;
};
static_assert(sizeof(TlvHeader) == TlvHeaderSize);
#pragma pack(pop)

enum MetaType : u16 {
    MetaNpdm = 0x0001,
    MetaIcon = 0x0003,
    MetaDisplayVersion = 0x0004,
    MetaTitleName = 0x0005,
    MetaLocalizedTitles = 0x0009,
    MetaLocalizedIcons = 0x000A,
};

bool Sha256(const u8* data, std::size_t size, std::array<u8, 0x20>& out) {
    unsigned int length = 0;
    EVP_Digest(data, size, out.data(), &length, EVP_sha256(), nullptr);
    return length == out.size();
}

/// A member file whose extent is zstd-compressed. Decompresses on first read
/// and caches the result (LRU-evicted) unless the file exceeds the cache cap.
class NupVfsFile final : public VfsFile {
public:
    NupVfsFile(VirtualFile backing_, u64 extent_offset_, u64 extent_size_, u64 uncompressed_size_,
               std::string name_, std::shared_ptr<NupDecompressCache> cache_,
               std::size_t cache_index_)
        : backing(std::move(backing_)), extent_offset(extent_offset_), extent_size(extent_size_),
          uncompressed_size(uncompressed_size_), name(std::move(name_)), cache(std::move(cache_)),
          cache_index(cache_index_), cache_enabled(uncompressed_size <= NupDecompressCache::DecompressCacheCap) {}

    std::string GetName() const override {
        return name;
    }

    std::size_t GetSize() const override {
        return static_cast<std::size_t>(uncompressed_size);
    }

    bool Resize(std::size_t) override {
        return false;
    }

    VirtualDir GetContainingDirectory() const override {
        return nullptr;
    }

    bool IsWritable() const override {
        return false;
    }

    bool IsReadable() const override {
        return true;
    }

    std::size_t Read(u8* data, std::size_t length, std::size_t offset) const override {
        if (offset >= uncompressed_size) {
            return 0;
        }
        length = std::min(length, static_cast<std::size_t>(uncompressed_size) - offset);

        {
            std::scoped_lock lock{cache->mutex};
            if (const auto* cached = cache->Find(cache_index)) {
                std::memcpy(data, cached->data() + offset, length);
                return length;
            }
        }

        // Miss: decompress without holding the lock, then publish and copy.
        std::vector<u8> scratch = Decompress();
        if (scratch.empty()) {
            return 0;
        }
        {
            std::scoped_lock lock{cache->mutex};
            if (cache_enabled) {
                cache->Insert(cache_index, scratch);
            }
            if (const auto* cached = cache->Find(cache_index)) {
                std::memcpy(data, cached->data() + offset, length);
                return length;
            }
        }
        std::memcpy(data, scratch.data() + offset, length);
        return length;
    }

    std::size_t Write(const u8*, std::size_t, std::size_t) override {
        return 0;
    }

    bool Rename(std::string_view new_name) override {
        name = std::string(new_name);
        return true;
    }

private:
    std::vector<u8> Decompress() const {
        if (extent_size > backing->GetSize() || extent_offset > backing->GetSize() - extent_size) {
            return {};
        }
        const auto compressed = backing->ReadBytes(static_cast<std::size_t>(extent_size),
                                                   static_cast<std::size_t>(extent_offset));
        if (compressed.size() != extent_size) {
            return {};
        }
        std::vector<u8> out(static_cast<std::size_t>(uncompressed_size));
        const std::size_t result =
            ZSTD_decompress(out.data(), out.size(), compressed.data(), compressed.size());
        if (ZSTD_isError(result) || result != out.size()) {
            LOG_ERROR(Loader, "NUP zstd decompression failed for {}", name);
            return {};
        }
        return out;
    }

    VirtualFile backing;
    u64 extent_offset;
    u64 extent_size;
    u64 uncompressed_size;
    std::string name;
    std::shared_ptr<NupDecompressCache> cache;
    std::size_t cache_index;
    bool cache_enabled;
};

} // namespace


bool NupContainer::IsNupFile(const VirtualFile& file) {
    if (file == nullptr || file->GetSize() < SuperblockSize) {
        return false;
    }
    std::array<u8, 4> magic{};
    file->ReadObject(&magic, 0);
    return magic == HeaderMagic;
}

NupContainer::NupContainer(VirtualFile file_)
    : file(std::move(file_)), cache(std::make_shared<NupDecompressCache>()) {
    if (file == nullptr) {
        return;
    }
    if (Parse()) {
        status = Loader::ResultStatus::Success;
    } else if (status == Loader::ResultStatus::ErrorNullFile) {
        status = Loader::ResultStatus::ErrorNUPBadFormat;
    }
}

NupContainer::~NupContainer() = default;

std::string NupContainer::last_error;

const std::string& NupContainer::LastError() {
    return last_error;
}

bool NupContainer::Fail(std::string reason) {
    LOG_ERROR(Loader, "NUP rejected: {}", reason);
    last_error = std::move(reason);
    status = Loader::ResultStatus::ErrorNUPBadFormat;
    return false;
}

bool NupContainer::Parse() {
    last_error.clear();
    const u64 actual_size = file->GetSize();
    if (actual_size < SuperblockSize) {
        return Fail(fmt::format("file is only {} bytes", actual_size));
    }
    Superblock super{};
    if (file->ReadObject(&super, 0) != sizeof(Superblock)) {
        return Fail("could not read the header");
    }
    if (super.magic != HeaderMagic) {
        return Fail(fmt::format("not a NUP v1 file (magic {:02X} {:02X} {:02X} {:02X})",
                                super.magic[0], super.magic[1], super.magic[2], super.magic[3]));
    }
    if (super.header_size < SuperblockSize) {
        return Fail(fmt::format("header size {:#x} is too small", static_cast<u32>(super.header_size)));
    }
    if (super.flags != 0) {
        // Flags from a newer packer; the layout fields are still checked below.
        LOG_WARNING(Loader, "NUP: unknown header flags {:#x}, ignored", static_cast<u32>(super.flags));
    }
    toc_offset = super.toc_offset;
    toc_size = super.toc_size;
    blob_offset = super.blob_offset;
    file_size = super.file_size;
    if (file_size > actual_size) {
        return Fail(fmt::format("file is incomplete: {} of {} bytes, copy it again", actual_size,
                                file_size));
    }
    if (file_size < actual_size) {
        // Padding added by a download or copy tool.
        LOG_WARNING(Loader, "NUP: {} trailing bytes after the container, ignored",
                    actual_size - file_size);
    }
    if (toc_offset < SuperblockSize || blob_offset < toc_offset + toc_size ||
        blob_offset % 0x10 != 0 || blob_offset > file_size) {
        return Fail(fmt::format("bad layout (toc {:#x}+{:#x}, blob {:#x}, size {:#x})", toc_offset,
                                toc_size, blob_offset, file_size));
    }

    const auto toc = file->ReadBytes(static_cast<std::size_t>(toc_size),
                                     static_cast<std::size_t>(toc_offset));
    if (toc.size() != toc_size) {
        return Fail("could not read the table of contents");
    }
    std::array<u8, 0x20> toc_hash{};
    if (!Sha256(toc.data(), toc.size(), toc_hash) || toc_hash != super.toc_sha256) {
        // Every record is still bounds-checked below, so a stale hash (some packers rewrite the
        // TOC without updating it) is not a reason to refuse the game.
        LOG_WARNING(Loader, "NUP TOC SHA-256 mismatch, continuing with the structure checks");
    }

    TocHeader header{};
    if (toc.size() < sizeof(header)) {
        return Fail("table of contents is too small");
    }
    std::memcpy(&header, toc.data(), sizeof(header));
    if (header.magic != TocMagic) {
        return Fail("table of contents has a bad magic");
    }
    if (header.package_count == 0) {
        return Fail("container has no packages");
    }
    if (static_cast<u32>(header.package_count) != super.package_count) {
        LOG_WARNING(Loader, "NUP: header says {} packages, TOC has {}",
                    static_cast<u32>(super.package_count), static_cast<u64>(header.package_count));
    }

    const u64 needed = TocHeaderSize + static_cast<u64>(header.package_count) * PackageRecordSize +
                       header.dir_count * DirRecordSize + header.file_count * FileRecordSize;
    const u64 children_offset = needed;
    const u64 children_bytes = header.pool_offset - needed;
    if (toc.size() < needed || header.pool_offset < needed ||
        header.pool_offset + header.pool_size > toc.size() || children_bytes % sizeof(u32) != 0) {
        return Fail("table of contents sections overlap or overflow");
    }
    const u8* base = toc.data();

    // Containers packed before the aligned record layout (upstream b8d2c08) carry the same magic
    // and version but packed records: size, hash and extent fields sit at other offsets. Try the
    // current layout first, then the older one.
    const RecordCounts counts{
        .package_count = static_cast<u64>(header.package_count),
        .dir_count = static_cast<u64>(header.dir_count),
        .file_count = static_cast<u64>(header.file_count),
        .pool_offset = static_cast<u64>(header.pool_offset),
        .pool_size = static_cast<u64>(header.pool_size),
        .children_offset = children_offset,
        .children_bytes = children_bytes,
    };
    if (ParseRecords(base, counts, false)) {
        return true;
    }
    const std::string aligned_error = last_error;
    if (ParseRecords(base, counts, true)) {
        LOG_INFO(Loader, "NUP: older packed record layout");
        last_error.clear();
        return true;
    }
    return Fail(fmt::format("{} / older layout: {}", aligned_error, last_error));
}

namespace {

template <typename T>
T ReadField(const u8* record, std::size_t offset) {
    T value{};
    std::memcpy(&value, record + offset, sizeof(T));
    return value;
}

} // namespace

bool NupContainer::ParseRecords(const u8* base, const RecordCounts& counts, bool legacy) {
    packages.clear();
    dirs.clear();
    files.clear();
    children.clear();

    // Offsets of the fields that moved between the two layouts.
    const std::size_t pkg_meta_offset = legacy ? 0x1C : 0x20;
    const std::size_t pkg_meta_size = legacy ? 0x24 : 0x28;
    const std::size_t file_size_at = legacy ? 0x0C : 0x08;
    const std::size_t file_sha_at = legacy ? 0x14 : 0x20;
    const std::size_t file_extent_offset_at = legacy ? 0x34 : 0x10;
    const std::size_t file_extent_size_at = legacy ? 0x3C : 0x18;
    const std::size_t file_codec_at = legacy ? 0x44 : 0x40;

    std::size_t pos = TocHeaderSize;
    packages.reserve(counts.package_count);
    for (u64 i = 0; i < counts.package_count; ++i) {
        const u8* record = base + pos;
        pos += PackageRecordSize;
        const u32 root_dir = ReadField<u32>(record, 0x08);
        const u32 exefs_dir = ReadField<u32>(record, 0x0C);
        const u32 romfs_dir = ReadField<u32>(record, 0x10);
        const u8 kind = record[0x18];
        const u8 flags = record[0x19];
        if (kind > static_cast<u8>(PackageKind::Addon) || root_dir >= counts.dir_count ||
            (exefs_dir != NoDir && exefs_dir >= counts.dir_count) ||
            (romfs_dir != NoDir && romfs_dir >= counts.dir_count)) {
            return Fail(fmt::format("package {} has a bad kind or directory index", i));
        }
        PackageInfo package;
        package.title_id = ReadField<u64>(record, 0x00);
        package.version = ReadField<u32>(record, 0x14);
        package.kind = static_cast<PackageKind>(kind);
        package.standalone_update = (flags & PackageFlagStandaloneUpdate) != 0;
        package.root_dir = root_dir;
        package.exefs_dir = exefs_dir;
        package.romfs_dir = romfs_dir;
        const u64 meta_offset = ReadField<u64>(record, pkg_meta_offset);
        const u32 meta_size = ReadField<u32>(record, pkg_meta_size);
        if (meta_size > 0 && meta_offset != 0 && meta_offset <= file_size &&
            meta_size <= file_size - meta_offset) {
            package.meta_offset = meta_offset;
            package.meta_size = meta_size;
        }
        packages.push_back(std::move(package));
    }

    dirs.resize(counts.dir_count);
    for (u64 i = 0; i < counts.dir_count; ++i) {
        DirRecord record{};
        std::memcpy(&record, base + pos, sizeof(record));
        pos += DirRecordSize;
        if (static_cast<u64>(record.first_child) + record.child_count > counts.children_bytes / sizeof(u32) ||
            static_cast<u64>(record.name_offset) + record.name_length > counts.pool_size) {
            return Fail(fmt::format("directory record {} is out of range", i));
        }
        dirs[i].name = std::string(reinterpret_cast<const char*>(base) + counts.pool_offset +
                                       record.name_offset,
                                   record.name_length);
        dirs[i].first_child = record.first_child;
        dirs[i].child_count = record.child_count;
    }

    // Packers also differ in smaller ways: extents relative to the blob region, unaligned raw
    // data, offsets left on empty files. Accepted as long as every extent lands inside the file.
    struct Entry {
        u32 name_offset;
        u32 name_length;
        u64 size;
        u64 extent_offset;
        u64 extent_size;
        std::array<u8, 0x20> sha256;
        u8 codec;
    };
    std::vector<Entry> entries(counts.file_count);
    for (u64 i = 0; i < counts.file_count; ++i) {
        const u8* record = base + pos;
        pos += FileRecordSize;
        Entry& entry = entries[i];
        entry.name_offset = ReadField<u32>(record, 0x00);
        entry.name_length = ReadField<u32>(record, 0x04);
        entry.size = ReadField<u64>(record, file_size_at);
        entry.extent_offset = ReadField<u64>(record, file_extent_offset_at);
        entry.extent_size = ReadField<u64>(record, file_extent_size_at);
        std::memcpy(entry.sha256.data(), record + file_sha_at, entry.sha256.size());
        entry.codec = record[file_codec_at];
        if (static_cast<u64>(entry.name_offset) + entry.name_length > counts.pool_size) {
            return Fail(fmt::format("file record {} has a name outside the string pool", i));
        }
        if (entry.codec > CodecZstd) {
            return Fail(fmt::format("file record {} uses unknown codec {}", i,
                                    static_cast<u32>(entry.codec)));
        }
    }
    const auto fits = [&](const Entry& entry, u64 bias) {
        const u64 offset = entry.extent_offset + bias;
        return entry.extent_size != 0 && offset >= entry.extent_offset && offset >= blob_offset &&
               offset <= file_size && entry.extent_size <= file_size - offset;
    };
    u64 bias = 0;
    for (const u64 candidate : {u64{0}, blob_offset}) {
        bias = candidate;
        const bool all_fit = std::all_of(entries.begin(), entries.end(), [&](const Entry& e) {
            return e.size == 0 || fits(e, candidate);
        });
        if (all_fit) {
            break;
        }
        if (candidate == blob_offset) {
            for (u64 i = 0; i < entries.size(); ++i) {
                const auto& e = entries[i];
                if (e.size != 0 && !fits(e, 0) && !fits(e, blob_offset)) {
                    return Fail(fmt::format(
                        "file record {} points outside the file (size {:#x}, extent {:#x}+{:#x}, "
                        "blob {:#x}, file {:#x})",
                        i, e.size, e.extent_offset, e.extent_size, blob_offset, file_size));
                }
            }
            return Fail("file records mix absolute and blob-relative offsets");
        }
    }
    if (bias != 0) {
        LOG_INFO(Loader, "NUP: extents are relative to the blob region");
    }

    files.resize(counts.file_count);
    for (u64 i = 0; i < counts.file_count; ++i) {
        const Entry& entry = entries[i];
        FileNode& node = files[i];
        node.name = std::string(reinterpret_cast<const char*>(base) + counts.pool_offset +
                                    entry.name_offset,
                                entry.name_length);
        node.size = entry.size;
        node.sha256 = entry.sha256;
        node.codec = entry.size != 0 ? entry.codec : CodecRaw;
        node.extent_offset = entry.size != 0 ? entry.extent_offset + bias : 0;
        node.extent_size = entry.size != 0 ? entry.extent_size : 0;
        if (node.codec == CodecRaw && node.extent_size < node.size) {
            return Fail(fmt::format("file record {} stores {:#x} raw bytes for a {:#x} byte file",
                                    i, node.extent_size, node.size));
        }
    }

    children.resize(counts.children_bytes / sizeof(u32));
    std::memcpy(children.data(), base + counts.children_offset, counts.children_bytes);
    for (const u32 child : children) {
        if (child >= counts.dir_count + counts.file_count) {
            return Fail("directory tree points past the last node");
        }
    }

    for (auto& package : packages) {
        if (!ParseMeta(package)) {
            // Titles and icons only; the game runs without them.
            LOG_WARNING(Loader, "NUP: metadata of title {:016X} is malformed, ignored",
                        package.title_id);
            package.npdm.clear();
        }
    }
    return true;
}

bool NupContainer::ParseMeta(PackageInfo& package) {
    if (package.meta_offset == 0) {
        return true;
    }
    const auto block = file->ReadBytes(static_cast<std::size_t>(package.meta_size),
                                       static_cast<std::size_t>(package.meta_offset));
    if (block.size() != package.meta_size) {
        return false;
    }
    std::size_t pos = 0;
    while (pos + TlvHeaderSize <= block.size()) {
        TlvHeader header{};
        std::memcpy(&header, block.data() + pos, sizeof(header));
        pos += TlvHeaderSize;
        if (pos + header.size > block.size()) {
            return false;
        }
        const u8* payload = block.data() + pos;
        pos += header.size;
        switch (header.type) {
        case MetaNpdm:
            package.npdm.assign(payload, payload + header.size);
            break;
        case MetaIcon:
            package.icon.assign(payload, payload + header.size);
            break;
        case MetaTitleName:
            package.title_name = std::string(reinterpret_cast<const char*>(payload), header.size);
            break;
        case MetaDisplayVersion:
            package.display_version =
                std::string(reinterpret_cast<const char*>(payload), header.size);
            break;
        case MetaLocalizedTitles:
        case MetaLocalizedIcons: {
            const bool is_title = header.type == MetaLocalizedTitles;
            std::size_t record_pos = 0;
            while (record_pos < header.size) {
                const u8 lang_length = payload[record_pos++];
                if (record_pos + lang_length + sizeof(u32) > header.size) {
                    return false;
                }
                const std::string lang(reinterpret_cast<const char*>(payload) + record_pos,
                                       lang_length);
                record_pos += lang_length;
                u32 data_length = 0;
                std::memcpy(&data_length, payload + record_pos, sizeof(data_length));
                record_pos += sizeof(data_length);
                if (record_pos + data_length > header.size) {
                    return false;
                }
                if (is_title) {
                    package.localized_titles.emplace_back(
                        lang, std::string(reinterpret_cast<const char*>(payload) + record_pos,
                                          data_length));
                } else {
                    package.localized_icons.emplace_back(
                        lang, std::vector<u8>(payload + record_pos,
                                              payload + record_pos + data_length));
                }
                record_pos += data_length;
            }
            break;
        }
        default:
            break;
        }
    }
    return true;
}

std::optional<std::size_t> NupContainer::FindPackage(PackageKind kind,
                                                     std::optional<u64> title_id) const {
    for (std::size_t i = 0; i < packages.size(); ++i) {
        if (packages[i].kind != kind) {
            continue;
        }
        if (title_id && packages[i].title_id != *title_id) {
            continue;
        }
        return i;
    }
    return std::nullopt;
}

std::optional<std::size_t> NupContainer::FindBasePackage() const {
    return FindPackage(PackageKind::Base);
}

std::optional<std::size_t> NupContainer::FindBestUpdatePackage() const {
    std::optional<std::size_t> best;
    for (std::size_t i = 0; i < packages.size(); ++i) {
        if (packages[i].kind != PackageKind::Update) {
            continue;
        }
        if (!best || packages[i].version > packages[*best].version) {
            best = i;
        }
    }
    return best;
}

VirtualFile NupContainer::OpenFile(std::size_t file_index) {
    if (file_index >= files.size()) {
        return nullptr;
    }
    const FileNode& node = files[file_index];
    if (node.size == 0) {
        return std::make_shared<VectorVfsFile>(std::vector<u8>{}, node.name);
    }
    if (node.codec == CodecRaw) {
        // node.size, not the extent: some packers pad raw extents.
        return std::make_shared<OffsetVfsFile>(
            file, static_cast<std::size_t>(node.size),
            static_cast<std::size_t>(node.extent_offset), node.name);
    }
    return std::make_shared<NupVfsFile>(file, node.extent_offset, node.extent_size, node.size,
                                        node.name, cache, file_index);
}

void NupContainer::BuildDirTree(u32 dir_index, VectorVfsDirectory& out) {
    const DirNode& node = dirs[dir_index];
    for (u32 slot = node.first_child; slot < node.first_child + node.child_count; ++slot) {
        const u32 child = children[slot];
        if (child >= dirs.size()) {
            out.AddFile(OpenFile(child - static_cast<u32>(dirs.size())));
        } else {
            auto sub = std::make_shared<VectorVfsDirectory>(std::vector<VirtualFile>{},
                                                            std::vector<VirtualDir>{},
                                                            dirs[child].name);
            BuildDirTree(child, *sub);
            out.AddDirectory(sub);
        }
    }
}

VirtualDir NupContainer::BuildPackageDir(u32 dir_index) {
    auto out = std::make_shared<VectorVfsDirectory>(std::vector<VirtualFile>{},
                                                    std::vector<VirtualDir>{}, dirs[dir_index].name);
    BuildDirTree(dir_index, *out);
    return out;
}

VirtualDir NupContainer::GetExeFSDir(std::size_t package_index) {
    if (package_index >= packages.size() || packages[package_index].exefs_dir == NoDir) {
        return nullptr;
    }
    if (exefs_dir_cache.size() <= package_index) {
        exefs_dir_cache.resize(packages.size());
    }
    if (exefs_dir_cache[package_index] == nullptr) {
        exefs_dir_cache[package_index] = BuildPackageDir(packages[package_index].exefs_dir);
    }
    return exefs_dir_cache[package_index];
}

VirtualDir NupContainer::GetRomFSDir(std::size_t package_index) {
    if (package_index >= packages.size() || packages[package_index].romfs_dir == NoDir) {
        return nullptr;
    }
    if (romfs_dir_cache.size() <= package_index) {
        romfs_dir_cache.resize(packages.size());
    }
    if (romfs_dir_cache[package_index] == nullptr) {
        romfs_dir_cache[package_index] = BuildPackageDir(packages[package_index].romfs_dir);
    }
    return romfs_dir_cache[package_index];
}

VirtualDir NupContainer::MergeShadowDirs(const VirtualDir& base, const VirtualDir& overlay) {
    if (base == nullptr) {
        return overlay;
    }
    if (overlay == nullptr) {
        return base;
    }

    std::map<std::string, VirtualFile, std::less<>> file_map;
    for (const auto& entry : base->GetFiles()) {
        file_map.insert_or_assign(entry->GetName(), entry);
    }
    for (const auto& entry : overlay->GetFiles()) {
        file_map.insert_or_assign(entry->GetName(), entry);
    }

    std::map<std::string, VirtualDir, std::less<>> dir_map;
    for (const auto& entry : base->GetSubdirectories()) {
        dir_map.insert_or_assign(entry->GetName(), entry);
    }
    for (const auto& entry : overlay->GetSubdirectories()) {
        const auto it = dir_map.find(entry->GetName());
        if (it != dir_map.end()) {
            dir_map.insert_or_assign(entry->GetName(), MergeShadowDirs(it->second, entry));
        } else {
            dir_map.insert_or_assign(entry->GetName(), entry);
        }
    }

    std::vector<VirtualFile> merged_files;
    merged_files.reserve(file_map.size());
    for (const auto& [_, entry] : file_map) {
        merged_files.push_back(entry);
    }
    std::vector<VirtualDir> merged_dirs;
    merged_dirs.reserve(dir_map.size());
    for (const auto& [_, entry] : dir_map) {
        merged_dirs.push_back(entry);
    }
    return std::make_shared<VectorVfsDirectory>(std::move(merged_files), std::move(merged_dirs),
                                                base->GetName());
}

std::vector<u8> NupContainer::ReadExtentRaw(const FileNode& node) const {
    return file->ReadBytes(static_cast<std::size_t>(node.extent_size),
                           static_cast<std::size_t>(node.extent_offset));
}

void NupContainer::LogDiagnostics() const {
    for (std::size_t i = 0; i < packages.size(); ++i) {
        const auto& p = packages[i];
        LOG_INFO(Loader, "NUP package {}: title {:016X} version {} kind {} standalone {} exefs {} romfs {}",
                 i, p.title_id, p.version, static_cast<u32>(p.kind), p.standalone_update,
                 p.exefs_dir, p.romfs_dir);
    }
    // Every file up to 32 MiB (the ones a game reads first: configs, archives' headers).
    constexpr u64 Limit = 32ULL << 20;
    std::size_t checked = 0, bad = 0, skipped = 0, compressed = 0;
    u64 bytes = 0;
    for (std::size_t i = 0; i < files.size(); ++i) {
        const FileNode& node = files[i];
        if (node.codec != CodecRaw) {
            ++compressed;
        }
        if (node.size == 0 || node.size > Limit) {
            ++skipped;
            continue;
        }
        std::vector<u8> content;
        if (node.codec == CodecRaw) {
            content = file->ReadBytes(static_cast<std::size_t>(node.size),
                                      static_cast<std::size_t>(node.extent_offset));
        } else {
            NupVfsFile view(file, node.extent_offset, node.extent_size, node.size, node.name,
                            cache, i);
            content = view.ReadAllBytes();
        }
        ++checked;
        bytes += node.size;
        std::array<u8, 0x20> hash{};
        if (content.size() != node.size || !Sha256(content.data(), content.size(), hash) ||
            hash != node.sha256) {
            ++bad;
            if (bad <= 40) {
                LOG_ERROR(Loader,
                          "NUP check: {} BAD (size {:#x}, read {:#x}, codec {}, extent {:#x}+{:#x}, "
                          "first bytes {:02X})",
                          node.name, node.size, content.size(), static_cast<u32>(node.codec),
                          node.extent_offset, node.extent_size,
                          fmt::join(content.begin(), content.begin() + std::min<std::size_t>(content.size(), 16), " "));
            }
        }
    }
    LOG_INFO(Loader, "NUP check: {} files, {} compressed, {} checked ({} MiB), {} bad, {} skipped",
             files.size(), compressed, checked, bytes >> 20, bad, skipped);
}

Loader::ResultStatus NupContainer::VerifyIntegrity(
    std::function<bool(std::size_t, std::size_t)> progress_callback) const {
    const std::size_t total = files.size();
    for (std::size_t i = 0; i < total; ++i) {
        const FileNode& node = files[i];
        std::vector<u8> content;
        if (node.size == 0) {
            content = ReadExtentRaw(node);
        } else if (node.codec == CodecRaw) {
            content = ReadExtentRaw(node);
        } else {
            NupVfsFile view(file, node.extent_offset, node.extent_size, node.size, node.name,
                            cache, i);
            content = view.ReadAllBytes();
        }
        if (content.size() != node.size) {
            LOG_ERROR(Loader, "NUP integrity check failed for {}: short read", node.name);
            return Loader::ResultStatus::ErrorIntegrityVerificationFailed;
        }
        std::array<u8, 0x20> hash{};
        if (!Sha256(content.data(), content.size(), hash) || hash != node.sha256) {
            LOG_ERROR(Loader, "NUP integrity check failed for {}: SHA-256 mismatch", node.name);
            return Loader::ResultStatus::ErrorIntegrityVerificationFailed;
        }
        if (progress_callback && !progress_callback(i + 1, total)) {
            return Loader::ResultStatus::ErrorIntegrityVerificationFailed;
        }
    }
    return Loader::ResultStatus::Success;
}

} // namespace FileSys
