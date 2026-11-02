// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

// SPDX-FileCopyrightText: Copyright 2023 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <array>
#include <cctype>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "core/core.h"
#include "core/debugger/debugger.h"
#include "core/hle/kernel/k_process.h"
#include "core/hle/kernel/k_thread.h"
#include "core/hle/kernel/svc.h"
#include "core/hle/kernel/svc_types.h"
#include "core/memory.h"
#include "core/reporter.h"

namespace Kernel::Svc {

namespace {

/// After a userspace panic: the printable strings on the stack near info1 and behind the stack's
/// pointers. A failed path lookup (rom:/...) or the assert's message usually sits there.
void LogNearbyStrings(Core::Memory::Memory& memory, u64 around) {
    if (around == 0) {
        return;
    }
    const auto printable = [](u8 c) { return c >= 0x20 && c < 0x7f; };
    std::set<std::string> seen;
    std::vector<std::string> found;
    const auto take = [&](const u8* data, std::size_t size, u64 address, bool must_start) {
        std::size_t i = 0;
        while (i < size) {
            std::size_t j = i;
            while (j < size && printable(data[j])) {
                ++j;
            }
            const bool terminated = j < size && data[j] == 0;
            if (j - i >= 5 && (terminated || j == size)) {
                std::string text(reinterpret_cast<const char*>(data + i), j - i);
                if (seen.insert(text).second && found.size() < 120) {
                    found.push_back(fmt::format("{:#x}: \"{}\"", address + i, text));
                }
            }
            if (must_start) {
                return;
            }
            i = j + 1;
        }
    };
    const u64 begin = (around & ~u64{0xF}) - 0x1000;
    const u64 end = around + 0x3000;
    for (u64 page = begin; page < end; page += 0x1000) {
        const u64 chunk_begin = page;
        if (!memory.IsValidVirtualAddressRange(chunk_begin, 0x1000)) {
            continue;
        }
        std::vector<u8> stack(0x1000);
        memory.ReadBlock(chunk_begin, stack.data(), stack.size());
        take(stack.data(), stack.size(), chunk_begin, false);
        for (std::size_t off = 0; off + 8 <= stack.size(); off += 8) {
            u64 pointer{};
            std::memcpy(&pointer, stack.data() + off, 8);
            if (pointer < 0x1000 || !memory.IsValidVirtualAddressRange(pointer, 0x100)) {
                continue;
            }
            std::array<u8, 0x100> text{};
            memory.ReadBlock(pointer, text.data(), text.size());
            take(text.data(), text.size(), pointer, true);
        }
    }
    LOG_CRITICAL(Debug_Emulated, "Strings near the panic ({}):", found.size());
    for (const auto& line : found) {
        LOG_CRITICAL(Debug_Emulated, "  {}", line);
    }
}

} // namespace

/// Break program execution
void Break(Core::System& system, BreakReason reason, u64 info1, u64 info2) {
    BreakReason break_reason =
        reason & static_cast<BreakReason>(~BreakReason::NotificationOnlyFlag);
    bool notification_only = True(reason & BreakReason::NotificationOnlyFlag);

    bool has_dumped_buffer{};
    std::vector<u8> debug_buffer;

    const auto handle_debug_buffer = [&](u64 addr, u64 sz) {
        if (sz == 0 || addr == 0 || has_dumped_buffer) {
            return;
        }

        auto& memory = GetCurrentMemory(system.Kernel());

        // This typically is an error code so we're going to assume this is the case
        if (sz == sizeof(u32)) {
            LOG_CRITICAL(Debug_Emulated, "debug_buffer_err_code={:X}", memory.Read32(addr));
        } else {
            // We don't know what's in here so we'll hexdump it
            debug_buffer.resize(sz);
            memory.ReadBlock(addr, debug_buffer.data(), sz);
            std::string hexdump;
            for (std::size_t i = 0; i < debug_buffer.size(); i++) {
                hexdump += fmt::format("{:02X} ", debug_buffer[i]);
                if ((i + 1) % 32 == 0) {
                    hexdump += '\n';
                }
            }
            LOG_CRITICAL(Debug_Emulated, "debug_buffer=\n{}", hexdump);
        }
        has_dumped_buffer = true;
    };
    switch (break_reason) {
    case BreakReason::Panic:
        LOG_CRITICAL(Debug_Emulated, "Userspace PANIC! info1={:#016x}, info2={:#016x}", info1,
                     info2);
        handle_debug_buffer(info1, info2);
        LogNearbyStrings(GetCurrentMemory(system.Kernel()), info1);
        break;
    case BreakReason::Assert:
        LOG_CRITICAL(Debug_Emulated, "Userspace Assertion failed! info1={:#016x}, info2={:#016x}",
                     info1, info2);
        handle_debug_buffer(info1, info2);
        LogNearbyStrings(GetCurrentMemory(system.Kernel()), info1);
        break;
    case BreakReason::User:
        LOG_WARNING(Debug_Emulated, "Userspace Break! {:#016x} with size {:#016x}", info1, info2);
        handle_debug_buffer(info1, info2);
        break;
    case BreakReason::PreLoadDll:
        LOG_INFO(Debug_Emulated,
                 "Userspace Attempting to load an NRO at {:#016x} with size {:#016x}", info1,
                 info2);
        break;
    case BreakReason::PostLoadDll:
        LOG_INFO(Debug_Emulated, "Userspace Loaded an NRO at {:#016x} with size {:#016x}", info1,
                 info2);
        break;
    case BreakReason::PreUnloadDll:
        LOG_INFO(Debug_Emulated,
                 "Userspace Attempting to unload an NRO at {:#016x} with size {:#016x}", info1,
                 info2);
        break;
    case BreakReason::PostUnloadDll:
        LOG_INFO(Debug_Emulated, "Userspace Unloaded an NRO at {:#016x} with size {:#016x}",
                 info1, info2);
        break;
    case BreakReason::CppException:
        LOG_CRITICAL(Debug_Emulated, "Signalling debugger. Uncaught C++ exception encountered.");
        break;
    default:
        LOG_WARNING(
            Debug_Emulated,
            "Signalling debugger, Unknown break reason {:#x}, info1={:#016x}, info2={:#016x}",
            reason, info1, info2);
        handle_debug_buffer(info1, info2);
        break;
    }

    system.GetReporter().SaveSvcBreakReport(
        static_cast<u32>(reason), notification_only, info1, info2,
        has_dumped_buffer ? std::make_optional(debug_buffer) : std::nullopt);

    if (!notification_only) {
        LOG_CRITICAL(
            Debug_Emulated,
            "Emulated program broke execution! reason={:#016x}, info1={:#016x}, info2={:#016x}",
            reason, info1, info2);

        handle_debug_buffer(info1, info2);

        system.CurrentPhysicalCore().LogBacktrace(system.Kernel());
    }

    const bool should_break = !notification_only;
    if (system.DebuggerEnabled() && should_break) {
        auto* thread = system.Kernel().GetCurrentEmuThread();
        system.GetDebugger().NotifyThreadStopped(thread);
        thread->RequestSuspend(system.Kernel(), Kernel::SuspendType::Debug);
    }
}

void ReturnFromException(Core::System& system, Result result) {
    UNIMPLEMENTED();
}

void Break64(Core::System& system, BreakReason break_reason, uint64_t arg, uint64_t size) {
    Break(system, break_reason, arg, size);
}

void Break64From32(Core::System& system, BreakReason break_reason, uint32_t arg, uint32_t size) {
    Break(system, break_reason, arg, size);
}

void ReturnFromException64(Core::System& system, Result result) {
    ReturnFromException(system, result);
}

void ReturnFromException64From32(Core::System& system, Result result) {
    ReturnFromException(system, result);
}

} // namespace Kernel::Svc
