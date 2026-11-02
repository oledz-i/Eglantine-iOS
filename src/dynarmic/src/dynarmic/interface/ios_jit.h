// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>

// iOS has no way for an app to create executable memory by itself. An attached debugger
// (StikDebug and similar) lifts that restriction, and on iOS 26 devices with TXM the debugger
// itself has to hand the pages over through a breakpoint protocol. Both paths can only run while
// the debugger is attached, so all JIT memory comes from one pool set up once per process and
// shared by every dynarmic instance afterwards.
namespace Dynarmic::IosJit {

enum class Status {
    NotInitialized,
    NoDebugger,  ///< CS_DEBUGGED is not set: JIT was not enabled for this launch
    DualMapped,  ///< iOS 16-18 style: RW pool remapped as RX
    TxmBroker,   ///< iOS 26 TXM: RX pool prepared by the debugger script, RW alias remapped
    Failed,
};

struct Region {
    std::uint32_t* wptr = nullptr;
    std::uint32_t* xptr = nullptr;
    std::size_t size = 0;
};

// Six cores at 48 MiB each plus room for a second process's smaller caches.
inline constexpr std::size_t DefaultPoolSize = 320 * 1024 * 1024;

/// Sets up the JIT pool. Call it as early as possible: on TXM devices the debugger script only
/// answers until it has detached. Later calls return the first result.
Status Initialize(std::size_t pool_size = DefaultPoolSize);

Status GetStatus();
const char* StatusString(Status status);
bool IsAvailable();
bool IsDebuggerAttached();
bool UsesTxmBroker();

/// Size of the pool that is still unused.
std::size_t FreeBytes();

/// Carves a region out of the pool (16 KiB aligned). When the pool can't fit `size`, the largest
/// free block is returned if it is at least `min_size`. Throws std::bad_alloc when JIT is
/// unavailable or nothing large enough is left.
Region Allocate(std::size_t size, std::size_t min_size = 8 * 1024 * 1024);
void Free(const Region& region);

}  // namespace Dynarmic::IosJit
