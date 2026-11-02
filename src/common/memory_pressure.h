// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <atomic>

namespace Common {

// Set by the frontend when the OS is about to run out of memory for us (iOS memory warnings,
// low os_proc_available_memory); caches drop what they can on their next tick.
inline std::atomic<bool> g_memory_pressure{false};

inline void SignalMemoryPressure() {
    g_memory_pressure.store(true, std::memory_order_relaxed);
}

inline bool ConsumeMemoryPressure() {
    return g_memory_pressure.exchange(false, std::memory_order_relaxed);
}

} // namespace Common
