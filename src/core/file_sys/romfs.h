// SPDX-FileCopyrightText: Copyright 2018 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

#include "core/file_sys/vfs/vfs.h"

namespace FileSys {

// Converts a RomFS binary blob to VFS Filesystem
// Returns nullptr on failure
VirtualDir ExtractRomFS(VirtualFile file);

// Converts a VFS filesystem into a RomFS binary
// Returns nullptr on failure
VirtualFile CreateRomFS(VirtualDir dir, VirtualDir ext = nullptr);

/// Diagnostics: build the RomFS and remember which file sits at which offset, so a traced
/// IStorage read can say which game file it touched (DescribeRomFSOffset).
VirtualFile CreateTrackedRomFS(VirtualDir dir);
std::string DescribeRomFSOffset(u64 offset, u64 length);

} // namespace FileSys
