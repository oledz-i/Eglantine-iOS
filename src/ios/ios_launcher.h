// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <string>

// UIKit pieces around the SDL frontend: the game picker shown before emulation starts, alerts,
// and the per-launch environment (user folder in Documents, JIT pool, memory warnings).
namespace IosLauncher {

/// Moves into Documents (so Eden's portable "user" folder lands where the Files app can see it),
/// creates the folder layout and sets up the JIT pool. Call first thing in SDL_AppInit.
void PrepareEnvironment();

/// True on the first launch, before any config file exists.
bool IsFirstLaunch();

/// Shows the game list and blocks (spinning the run loop) until a game is picked. Returns the
/// path to hand to Core::System::Load.
std::string PickGame();

/// Blocking alert; used for errors before and during boot.
void ShowAlert(const std::string& title, const std::string& message);

/// Short status line for the JIT, e.g. "JIT enabled (TXM, debugger prepared)".
std::string JitStatus();
bool JitAvailable();

}  // namespace IosLauncher
