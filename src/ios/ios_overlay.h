// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

namespace InputCommon {
class VirtualGamepad;
}

// On-screen controller drawn over the game: two sticks, d-pad, ABXY, shoulders, +/-, Home and
// Capture, plus a small FPS readout and a menu button. It feeds Eden's virtual gamepad (the same
// path Android's overlay uses), hides itself while a hardware controller is connected, and lets
// touches that miss every control through to the emulated touchscreen.
namespace IosOverlay {

/// Adds the overlay on top of the SDL window's view. Call after the emulation window exists.
void Attach(InputCommon::VirtualGamepad* gamepad);

/// Overlay preferences, stored in NSUserDefaults and edited from the settings screen.
bool Enabled();
void SetEnabled(bool enabled);
float Opacity();
void SetOpacity(float opacity);
bool Haptics();
void SetHaptics(bool haptics);
bool ShowFps();
void SetShowFps(bool show);

} // namespace IosOverlay
