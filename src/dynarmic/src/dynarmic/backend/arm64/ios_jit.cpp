// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "dynarmic/interface/ios_jit.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <dirent.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace Dynarmic::IosJit {

namespace {

constexpr unsigned int CS_OPS_STATUS = 0;
constexpr std::uint32_t CS_DEBUGGED = 0x10000000;
constexpr std::size_t PageSize = 16 * 1024;

// StikDebug universal protocol: command in x16, address/length in x0/x1, result in x0. The
// debugger steps over the brk. A brk nobody answers kills the process, so these are only called
// while a debugger is attached.
extern "C" __attribute__((noinline, naked)) void* EglantineJit26PrepareRegion(void*, std::size_t) {
    asm volatile("mov x16, #1\n"
                 "brk #0xf00d\n"
                 "ret\n");
}

extern "C" __attribute__((noinline, naked)) void EglantineJit26Detach() {
    asm volatile("mov x16, #0\n"
                 "brk #0xf00d\n"
                 "ret\n");
}

struct Block {
    std::size_t offset;
    std::size_t size;
};

struct Pool {
    std::mutex mutex;
    bool initialized = false;
    Status status = Status::NotInitialized;
    std::uint8_t* wbase = nullptr;
    std::uint8_t* xbase = nullptr;
    std::size_t size = 0;
    std::vector<Block> free_list;
};

Pool& GetPool() {
    static Pool pool;
    return pool;
}

void Log(const char* fmt, const char* a = "", unsigned long long b = 0, unsigned long long c = 0) {
    std::fprintf(stderr, "[ios_jit] ");
    std::fprintf(stderr, fmt, a, b, c);
    std::fprintf(stderr, "\n");
}

bool HasCsDebugged() {
    std::uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

bool IsTraced() {
    kinfo_proc info{};
    std::size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int OsMajorVersion() {
    char version[32]{};
    std::size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, nullptr, 0) != 0) {
        return 0;
    }
    return std::atoi(version);
}

bool FileExists(const std::string& path) {
    struct stat st {};
    return stat(path.c_str(), &st) == 0;
}

std::vector<std::string> ListDir(const std::string& path) {
    std::vector<std::string> entries;
    if (DIR* dir = opendir(path.c_str())) {
        while (const dirent* entry = readdir(dir)) {
            if (entry->d_name[0] != '.') {
                entries.emplace_back(entry->d_name);
            }
        }
        closedir(dir);
    }
    return entries;
}

// TXM ships as its own firmware image in the Preboot volume:
// /System/Volumes/Preboot/<uuid>/boot/<hash>/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4
// EGLANTINE_TXM=1/0 overrides the detection.
int DetectTxm() {
    if (const char* value = std::getenv("EGLANTINE_TXM"); value != nullptr && value[0] != '\0') {
        return value[0] == '1' ? 1 : 0;
    }
    static constexpr const char* Suffix = "/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4";
    const std::string preboot = "/System/Volumes/Preboot";
    const auto volumes = ListDir(preboot);
    if (volumes.empty()) {
        return -1;
    }
    for (const auto& volume : volumes) {
        const std::string root = preboot + "/" + volume;
        if (FileExists(root + Suffix)) {
            return 1;
        }
        for (const auto& hash : ListDir(root + "/boot")) {
            if (FileExists(root + "/boot/" + hash + Suffix)) {
                return 1;
            }
        }
    }
    return 0;
}

bool MakeWritableAlias(std::uint8_t* xbase, std::size_t size, std::uint8_t** wbase) {
    vm_address_t alias = 0;
    vm_prot_t cur_prot = VM_PROT_NONE;
    vm_prot_t max_prot = VM_PROT_NONE;
    kern_return_t ret = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                 reinterpret_cast<vm_address_t>(xbase), false, &cur_prot, &max_prot,
                                 VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        Log("vm_remap (RW alias) failed: %s", mach_error_string(ret));
        return false;
    }
    if (mprotect(reinterpret_cast<void*>(alias), size, PROT_READ | PROT_WRITE) != 0) {
        ret = vm_protect(mach_task_self(), alias, size, true, VM_PROT_READ | VM_PROT_WRITE);
        if (ret == KERN_SUCCESS) {
            ret = vm_protect(mach_task_self(), alias, size, false, VM_PROT_READ | VM_PROT_WRITE);
        }
        if (ret != KERN_SUCCESS) {
            Log("RW alias protection failed: %s", strerror(errno));
            vm_deallocate(mach_task_self(), alias, size);
            return false;
        }
    }
    *wbase = reinterpret_cast<std::uint8_t*>(alias);
    return true;
}

bool SetupTxm(Pool& pool, std::size_t size) {
    void* region = EglantineJit26PrepareRegion(nullptr, size);
    if (region == nullptr || region == MAP_FAILED) {
        Log("debugger did not prepare a JIT region");
        EglantineJit26Detach();
        return false;
    }
    std::uint8_t* wbase = nullptr;
    const bool ok = MakeWritableAlias(static_cast<std::uint8_t*>(region), size, &wbase);
    // Detach in every case: the script stays attached until it is told to leave.
    EglantineJit26Detach();
    if (!ok) {
        return false;
    }
    pool.xbase = static_cast<std::uint8_t*>(region);
    pool.wbase = wbase;
    return true;
}

bool SetupDualMapping(Pool& pool, std::size_t size) {
    void* wmem = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (wmem == MAP_FAILED) {
        Log("mmap of JIT pool failed: %s", strerror(errno));
        return false;
    }
    vm_address_t xmem = 0;
    vm_prot_t cur_prot = VM_PROT_NONE;
    vm_prot_t max_prot = VM_PROT_NONE;
    const kern_return_t ret = vm_remap(mach_task_self(), &xmem, size, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR,
                                       mach_task_self(), reinterpret_cast<vm_address_t>(wmem), false,
                                       &cur_prot, &max_prot, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        Log("vm_remap (RX alias) failed: %s", mach_error_string(ret));
        munmap(wmem, size);
        return false;
    }
    if (mprotect(reinterpret_cast<void*>(xmem), size, PROT_READ | PROT_EXEC) != 0) {
        Log("mprotect RX failed: %s", strerror(errno));
        vm_deallocate(mach_task_self(), xmem, size);
        munmap(wmem, size);
        return false;
    }
    pool.wbase = static_cast<std::uint8_t*>(wmem);
    pool.xbase = reinterpret_cast<std::uint8_t*>(xmem);
    return true;
}

}  // namespace

Status Initialize(std::size_t pool_size) {
    Pool& pool = GetPool();
    std::scoped_lock lock{pool.mutex};
    if (pool.initialized) {
        return pool.status;
    }
    pool.initialized = true;
    pool_size = (pool_size + PageSize - 1) & ~(PageSize - 1);

    if (!HasCsDebugged()) {
        pool.status = Status::NoDebugger;
        Log("CS_DEBUGGED not set; JIT unavailable (launch through StikDebug)");
        return pool.status;
    }

    const int os_major = OsMajorVersion();
    const int txm = DetectTxm();
    // When the Preboot volume can't be read, iOS 26 is assumed to need the broker; that is the
    // only path that works on TXM devices and StikDebug's universal script also answers it on
    // others with its TXM override.
    const bool use_broker = os_major >= 26 && txm != 0;
    Log("iOS %s, TXM detection %llu, broker %llu", std::to_string(os_major).c_str(),
        static_cast<unsigned long long>(txm + 1), use_broker ? 1ULL : 0ULL);

    bool ok = false;
    if (use_broker) {
        if (!IsTraced()) {
            Log("TXM path needs a live debugger, but none is attached");
        } else {
            ok = SetupTxm(pool, pool_size);
        }
        if (ok) {
            pool.status = Status::TxmBroker;
        }
    } else {
        ok = SetupDualMapping(pool, pool_size);
        if (ok) {
            pool.status = Status::DualMapped;
        }
    }

    if (!ok) {
        pool.status = Status::Failed;
        return pool.status;
    }
    pool.size = pool_size;
    pool.free_list.push_back({0, pool_size});
    Log("JIT pool ready: %s, %llu MiB", StatusString(pool.status),
        static_cast<unsigned long long>(pool_size >> 20));
    return pool.status;
}

Status GetStatus() {
    Pool& pool = GetPool();
    std::scoped_lock lock{pool.mutex};
    return pool.status;
}

const char* StatusString(Status status) {
    switch (status) {
    case Status::NotInitialized:
        return "not initialized";
    case Status::NoDebugger:
        return "JIT not enabled";
    case Status::DualMapped:
        return "JIT enabled (dual mapping)";
    case Status::TxmBroker:
        return "JIT enabled (TXM, debugger prepared)";
    case Status::Failed:
        return "JIT setup failed";
    }
    return "unknown";
}

bool IsAvailable() {
    const Status status = GetStatus();
    return status == Status::DualMapped || status == Status::TxmBroker;
}

bool IsDebuggerAttached() {
    return HasCsDebugged();
}

bool UsesTxmBroker() {
    return GetStatus() == Status::TxmBroker;
}

std::size_t FreeBytes() {
    Pool& pool = GetPool();
    std::scoped_lock lock{pool.mutex};
    std::size_t total = 0;
    for (const auto& block : pool.free_list) {
        total += block.size;
    }
    return total;
}

Region Allocate(std::size_t size, std::size_t min_size) {
    // Lazy setup only helps on the dual-mapping path; on TXM the script must still be attached.
    if (GetStatus() == Status::NotInitialized) {
        Initialize();
    }
    Pool& pool = GetPool();
    std::scoped_lock lock{pool.mutex};
    if (pool.status != Status::DualMapped && pool.status != Status::TxmBroker) {
        throw std::bad_alloc{};
    }
    size = (size + PageSize - 1) & ~(PageSize - 1);
    min_size = std::min((min_size + PageSize - 1) & ~(PageSize - 1), size);
    auto it = std::find_if(pool.free_list.begin(), pool.free_list.end(),
                           [size](const Block& block) { return block.size >= size; });
    if (it == pool.free_list.end()) {
        it = std::max_element(pool.free_list.begin(), pool.free_list.end(),
                              [](const Block& a, const Block& b) { return a.size < b.size; });
        if (it == pool.free_list.end() || it->size < min_size) {
            Log("JIT pool exhausted (%s), wanted %llu MiB", "", static_cast<unsigned long long>(size >> 20));
            throw std::bad_alloc{};
        }
        Log("JIT pool low (%s), %llu MiB cache instead of %llu MiB", "",
            static_cast<unsigned long long>(it->size >> 20), static_cast<unsigned long long>(size >> 20));
        size = it->size;
    }
    const std::size_t offset = it->offset;
    it->offset += size;
    it->size -= size;
    if (it->size == 0) {
        pool.free_list.erase(it);
    }
    return Region{
        .wptr = reinterpret_cast<std::uint32_t*>(pool.wbase + offset),
        .xptr = reinterpret_cast<std::uint32_t*>(pool.xbase + offset),
        .size = size,
    };
}

void Free(const Region& region) {
    if (region.size == 0) {
        return;
    }
    Pool& pool = GetPool();
    std::scoped_lock lock{pool.mutex};
    const std::size_t offset = reinterpret_cast<std::uint8_t*>(region.xptr) - pool.xbase;
    // Drop the pages so a freed code cache does not stay in the footprint. Not on TXM: a page
    // that gets refaulted there would lose the execute permission the debugger gave it.
    if (pool.status == Status::DualMapped) {
        madvise(pool.wbase + offset, region.size, MADV_FREE_REUSABLE);
    }

    auto it = std::lower_bound(pool.free_list.begin(), pool.free_list.end(), offset,
                               [](const Block& block, std::size_t value) { return block.offset < value; });
    it = pool.free_list.insert(it, Block{offset, region.size});
    if (const auto next = std::next(it); next != pool.free_list.end() && it->offset + it->size == next->offset) {
        it->size += next->size;
        pool.free_list.erase(next);
    }
    if (it != pool.free_list.begin()) {
        const auto prev = std::prev(it);
        if (prev->offset + prev->size == it->offset) {
            prev->size += it->size;
            pool.free_list.erase(it);
        }
    }
}

}  // namespace Dynarmic::IosJit
