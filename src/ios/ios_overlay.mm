// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

#include "input_common/drivers/virtual_gamepad.h"
#include "ios/ios_overlay.h"

using VirtualButton = InputCommon::VirtualGamepad::VirtualButton;
using VirtualStick = InputCommon::VirtualGamepad::VirtualStick;

namespace {

NSString* const EnabledKey = @"EGTouchControlsEnabled";
NSString* const OpacityKey = @"EGTouchControlsOpacity";
NSString* const HapticsKey = @"EGTouchControlsHaptics";
NSString* const FpsKey = @"EGShowFps";

void RegisterDefaults() {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        EnabledKey : @YES,
        OpacityKey : @0.55,
        HapticsKey : @YES,
        FpsKey : @YES,
    }];
}

InputCommon::VirtualGamepad* g_gamepad = nullptr;

// Player 1 and the handheld controller: which one the game reads depends on docked mode.
constexpr std::size_t Ports[] = {0, 8};

void SendButton(int button, bool pressed) {
    if (g_gamepad == nullptr) {
        return;
    }
    for (const std::size_t port : Ports) {
        g_gamepad->SetButtonState(port, button, pressed);
    }
}

void SendStick(VirtualStick stick, float x, float y) {
    if (g_gamepad == nullptr) {
        return;
    }
    for (const std::size_t port : Ports) {
        g_gamepad->SetStickPosition(port, stick, x, y);
    }
}

enum class Kind { Button, Stick, Dpad, Menu };

struct Control {
    Kind kind;
    int button = -1;
    VirtualStick stick = VirtualStick::Left;
    NSString* __strong label = nil;
    bool round = true;
    CGRect frame = CGRectZero;
    bool pressed = false;
    CGPoint knob = CGPointZero;  // stick offset in points
    int dpad_bits = 0;           // 1 up, 2 down, 4 left, 8 right
};

} // namespace

@interface EGOverlayView : UIView
@end

@implementation EGOverlayView {
    std::vector<Control> _controls;
    std::unordered_map<const void*, size_t> _touches;
    UIImpactFeedbackGenerator* _haptic;
    UILabel* _fps;
    NSTimer* _timer;
    bool _showControls; // hidden controls still leave the menu button and FPS readout
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [_haptic prepare];

        _fps = [[UILabel alloc] init];
        _fps.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _fps.textColor = UIColor.whiteColor;
        _fps.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        _fps.layer.cornerRadius = 6;
        _fps.layer.masksToBounds = YES;
        _fps.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_fps];

        [self buildControls];
        [self refreshVisibility];
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(refreshVisibility) name:GCControllerDidConnectNotification object:nil];
        [center addObserver:self selector:@selector(refreshVisibility) name:GCControllerDidDisconnectNotification object:nil];
        [center addObserver:self selector:@selector(refreshVisibility) name:NSUserDefaultsDidChangeNotification object:nil];
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateFps)
                                                userInfo:nil
                                                 repeats:YES];
    }
    return self;
}

- (void)buildControls {
    const auto button = [](VirtualButton id, NSString* label, bool round) {
        Control c{Kind::Button};
        c.button = static_cast<int>(id);
        c.label = label;
        c.round = round;
        return c;
    };
    Control left_stick{Kind::Stick};
    left_stick.stick = VirtualStick::Left;
    Control right_stick{Kind::Stick};
    right_stick.stick = VirtualStick::Right;
    Control menu{Kind::Menu};
    menu.label = @"≡";
    _controls = {
        left_stick,
        right_stick,
        Control{Kind::Dpad},
        button(VirtualButton::ButtonA, @"A", true),
        button(VirtualButton::ButtonB, @"B", true),
        button(VirtualButton::ButtonX, @"X", true),
        button(VirtualButton::ButtonY, @"Y", true),
        button(VirtualButton::TriggerL, @"L", false),
        button(VirtualButton::TriggerZL, @"ZL", false),
        button(VirtualButton::TriggerR, @"R", false),
        button(VirtualButton::TriggerZR, @"ZR", false),
        button(VirtualButton::ButtonMinus, @"−", true),
        button(VirtualButton::ButtonPlus, @"+", true),
        button(VirtualButton::ButtonCapture, @"◉", true),
        button(VirtualButton::ButtonHome, @"⌂", true),
        button(VirtualButton::StickL, @"LS", true),
        button(VirtualButton::StickR, @"RS", true),
        menu,
    };
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat w = self.bounds.size.width;
    const CGFloat h = self.bounds.size.height;
    const UIEdgeInsets safe = self.safeAreaInsets;
    const bool landscape = w > h;
    // In portrait the game sits at the top and the controls take the bottom part.
    const CGFloat u = landscape ? h : std::min(w * 0.95, h * 0.55);
    const CGFloat top = landscape ? 0 : h - u - safe.bottom * 0.5;
    const CGFloat left = safe.left + (landscape ? 8 : 0);
    const CGFloat right = w - safe.right - (landscape ? 8 : 0);
    const CGFloat face = u * 0.15;

    const auto circle = [](CGFloat x, CGFloat y, CGFloat d) {
        return CGRectMake(x - d / 2, y - d / 2, d, d);
    };
    const auto pill = [](CGFloat x, CGFloat y, CGFloat cw, CGFloat ch) {
        return CGRectMake(x - cw / 2, y - ch / 2, cw, ch);
    };
    const CGFloat abxy_x = right - u * 0.24;
    const CGFloat abxy_y = top + u * 0.56;
    const CGFloat gap = face * 0.98;

    for (Control& c : _controls) {
        switch (c.kind) {
        case Kind::Stick:
            c.frame = c.stick == VirtualStick::Left ? circle(left + u * 0.22, top + u * 0.54, u * 0.32)
                                                    : circle(right - u * 0.46, top + u * 0.84, u * 0.26);
            break;
        case Kind::Dpad:
            c.frame = circle(left + u * 0.46, top + u * 0.84, u * 0.30);
            break;
        case Kind::Menu:
            c.frame = circle(w / 2, top + u * 0.09, face * 0.62);
            break;
        case Kind::Button:
            switch (static_cast<VirtualButton>(c.button)) {
            case VirtualButton::ButtonA: c.frame = circle(abxy_x + gap, abxy_y, face); break;
            case VirtualButton::ButtonB: c.frame = circle(abxy_x, abxy_y + gap, face); break;
            case VirtualButton::ButtonX: c.frame = circle(abxy_x, abxy_y - gap, face); break;
            case VirtualButton::ButtonY: c.frame = circle(abxy_x - gap, abxy_y, face); break;
            case VirtualButton::TriggerZL: c.frame = pill(left + u * 0.17, top + u * 0.09, u * 0.26, u * 0.10); break;
            case VirtualButton::TriggerL: c.frame = pill(left + u * 0.17, top + u * 0.21, u * 0.26, u * 0.10); break;
            case VirtualButton::TriggerZR: c.frame = pill(right - u * 0.17, top + u * 0.09, u * 0.26, u * 0.10); break;
            case VirtualButton::TriggerR: c.frame = pill(right - u * 0.17, top + u * 0.21, u * 0.26, u * 0.10); break;
            case VirtualButton::ButtonMinus: c.frame = circle(w / 2 - u * 0.17, top + u * 0.09, face * 0.62); break;
            case VirtualButton::ButtonPlus: c.frame = circle(w / 2 + u * 0.17, top + u * 0.09, face * 0.62); break;
            case VirtualButton::ButtonCapture: c.frame = circle(w / 2 - u * 0.17, top + u * 0.22, face * 0.55); break;
            case VirtualButton::ButtonHome: c.frame = circle(w / 2 + u * 0.17, top + u * 0.22, face * 0.55); break;
            case VirtualButton::StickL: c.frame = circle(left + u * 0.42, top + u * 0.36, face * 0.55); break;
            case VirtualButton::StickR: c.frame = circle(right - u * 0.66, top + u * 0.92, face * 0.55); break;
            default: break;
            }
            break;
        }
    }
    _fps.frame = CGRectMake(w / 2 - 60, top + u * 0.30, 120, 20);
    [self setNeedsDisplay];
}

- (void)refreshVisibility {
    const bool controller = GCController.controllers.count > 0;
    const bool show = IosOverlay::Enabled() && !controller;
    self.alpha = show ? IosOverlay::Opacity() : 1.0;
    _showControls = show;
    _fps.hidden = !IosOverlay::ShowFps();
    [self setNeedsDisplay];
}

- (void)updateFps {
    if (_fps.hidden) {
        return;
    }
    int count = 0;
    SDL_Window** windows = SDL_GetWindows(&count);
    if (windows == nullptr) {
        return;
    }
    const char* title = count > 0 ? SDL_GetWindowTitle(windows[0]) : nullptr;
    SDL_free(windows);
    if (title == nullptr) {
        return;
    }
    NSString* text = @(title);
    const NSRange range = [text rangeOfString:@"FPS:"];
    _fps.text = range.location != NSNotFound ? [text substringFromIndex:range.location] : @"Loading…";
}

- (void)drawRect:(CGRect)rect {
    UIColor* stroke = [UIColor colorWithWhite:1 alpha:0.85];
    UIColor* fill = [UIColor colorWithWhite:0 alpha:0.35];
    UIColor* pressed = [UIColor colorWithWhite:1 alpha:0.5];
    for (const Control& c : _controls) {
        if (!_showControls && c.kind != Kind::Menu) {
            continue;
        }
        switch (c.kind) {
        case Kind::Stick: {
            UIBezierPath* base = [UIBezierPath bezierPathWithOvalInRect:c.frame];
            [fill setFill];
            [base fill];
            [stroke setStroke];
            base.lineWidth = 2;
            [base stroke];
            const CGFloat knob = c.frame.size.width * 0.42;
            const CGPoint center = CGPointMake(CGRectGetMidX(c.frame) + c.knob.x, CGRectGetMidY(c.frame) + c.knob.y);
            UIBezierPath* top = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x - knob / 2, center.y - knob / 2, knob, knob)];
            [(c.pressed ? pressed : [UIColor colorWithWhite:1 alpha:0.3]) setFill];
            [top fill];
            [stroke setStroke];
            [top stroke];
            break;
        }
        case Kind::Dpad: {
            const CGRect f = c.frame;
            const CGFloat arm = f.size.width / 3;
            const struct {
                CGRect r;
                int bit;
            } arms[] = {
                {CGRectMake(f.origin.x + arm, f.origin.y, arm, arm), 1},
                {CGRectMake(f.origin.x + arm, f.origin.y + 2 * arm, arm, arm), 2},
                {CGRectMake(f.origin.x, f.origin.y + arm, arm, arm), 4},
                {CGRectMake(f.origin.x + 2 * arm, f.origin.y + arm, arm, arm), 8},
            };
            UIBezierPath* center = [UIBezierPath bezierPathWithRect:CGRectMake(f.origin.x + arm, f.origin.y + arm, arm, arm)];
            [fill setFill];
            [center fill];
            for (const auto& a : arms) {
                UIBezierPath* p = [UIBezierPath bezierPathWithRoundedRect:a.r cornerRadius:6];
                [((c.dpad_bits & a.bit) ? pressed : fill) setFill];
                [p fill];
                [stroke setStroke];
                p.lineWidth = 2;
                [p stroke];
            }
            break;
        }
        case Kind::Button:
        case Kind::Menu: {
            UIBezierPath* p = c.round ? [UIBezierPath bezierPathWithOvalInRect:c.frame]
                                      : [UIBezierPath bezierPathWithRoundedRect:c.frame cornerRadius:c.frame.size.height / 2];
            [(c.pressed ? pressed : fill) setFill];
            [p fill];
            [stroke setStroke];
            p.lineWidth = 2;
            [p stroke];
            if (c.label != nil) {
                const CGFloat size = std::max<CGFloat>(11, c.frame.size.height * 0.42);
                NSDictionary* attrs = @{
                    NSFontAttributeName : [UIFont systemFontOfSize:size weight:UIFontWeightBold],
                    NSForegroundColorAttributeName : UIColor.whiteColor,
                };
                const CGSize text = [c.label sizeWithAttributes:attrs];
                [c.label drawAtPoint:CGPointMake(CGRectGetMidX(c.frame) - text.width / 2,
                                                 CGRectGetMidY(c.frame) - text.height / 2)
                      withAttributes:attrs];
            }
            break;
        }
        }
    }
}

- (NSInteger)controlAt:(CGPoint)point {
    // Generous hit areas: thumbs are bigger than the drawn buttons.
    NSInteger best = -1;
    CGFloat best_distance = CGFLOAT_MAX;
    for (size_t i = 0; i < _controls.size(); ++i) {
        const Control& c = _controls[i];
        if (!_showControls && c.kind != Kind::Menu) {
            continue;
        }
        const CGFloat slack = c.kind == Kind::Stick ? 30 : 12;
        if (!CGRectContainsPoint(CGRectInset(c.frame, -slack, -slack), point)) {
            continue;
        }
        const CGFloat dx = point.x - CGRectGetMidX(c.frame);
        const CGFloat dy = point.y - CGRectGetMidY(c.frame);
        const CGFloat distance = dx * dx + dy * dy;
        if (distance < best_distance) {
            best_distance = distance;
            best = static_cast<NSInteger>(i);
        }
    }
    return best;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    // Anything that isn't a control goes to the game's touchscreen underneath.
    return [self controlAt:point] >= 0 ? self : nil;
}

- (void)updateControl:(Control&)c at:(CGPoint)point began:(bool)began {
    switch (c.kind) {
    case Kind::Button:
        if (began) {
            c.pressed = true;
            SendButton(c.button, true);
            [self buzz];
        }
        break;
    case Kind::Stick: {
        const CGFloat radius = c.frame.size.width / 2;
        CGFloat dx = point.x - CGRectGetMidX(c.frame);
        CGFloat dy = point.y - CGRectGetMidY(c.frame);
        const CGFloat length = std::sqrt(dx * dx + dy * dy);
        if (length > radius) {
            dx *= radius / length;
            dy *= radius / length;
        }
        c.knob = CGPointMake(dx, dy);
        c.pressed = true;
        // Screen y grows downwards; the Switch stick's up is positive.
        SendStick(c.stick, static_cast<float>(dx / radius), static_cast<float>(-dy / radius));
        break;
    }
    case Kind::Dpad: {
        const CGFloat dx = point.x - CGRectGetMidX(c.frame);
        const CGFloat dy = point.y - CGRectGetMidY(c.frame);
        const CGFloat dead = c.frame.size.width * 0.12;
        int bits = 0;
        // Diagonals when the thumb sits between two arms.
        if (dy < -dead && std::fabs(dx) < std::fabs(dy) * 2.2) bits |= 1;
        if (dy > dead && std::fabs(dx) < std::fabs(dy) * 2.2) bits |= 2;
        if (dx < -dead && std::fabs(dy) < std::fabs(dx) * 2.2) bits |= 4;
        if (dx > dead && std::fabs(dy) < std::fabs(dx) * 2.2) bits |= 8;
        [self setDpad:c bits:bits];
        break;
    }
    case Kind::Menu:
        if (began) {
            c.pressed = true;
        }
        break;
    }
    [self setNeedsDisplay];
}

- (void)setDpad:(Control&)c bits:(int)bits {
    const int changed = bits ^ c.dpad_bits;
    if (changed == 0) {
        return;
    }
    const struct {
        int bit;
        VirtualButton button;
    } map[] = {{1, VirtualButton::ButtonUp},
               {2, VirtualButton::ButtonDown},
               {4, VirtualButton::ButtonLeft},
               {8, VirtualButton::ButtonRight}};
    for (const auto& m : map) {
        if (changed & m.bit) {
            SendButton(static_cast<int>(m.button), (bits & m.bit) != 0);
        }
    }
    if (bits & ~c.dpad_bits) {
        [self buzz];
    }
    c.dpad_bits = bits;
}

- (void)releaseControl:(Control&)c {
    switch (c.kind) {
    case Kind::Button:
        SendButton(c.button, false);
        break;
    case Kind::Stick:
        c.knob = CGPointZero;
        SendStick(c.stick, 0, 0);
        break;
    case Kind::Dpad:
        [self setDpad:c bits:0];
        break;
    case Kind::Menu:
        if (c.pressed) {
            [self showMenu];
        }
        break;
    }
    c.pressed = false;
    [self setNeedsDisplay];
}

- (void)buzz {
    if (IosOverlay::Haptics()) {
        [_haptic impactOccurred];
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        const CGPoint point = [touch locationInView:self];
        const NSInteger index = [self controlAt:point];
        if (index < 0) {
            continue;
        }
        _touches[(__bridge const void*)touch] = static_cast<size_t>(index);
        [self updateControl:_controls[index] at:point began:true];
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        const auto it = _touches.find((__bridge const void*)touch);
        if (it == _touches.end()) {
            continue;
        }
        [self updateControl:_controls[it->second] at:[touch locationInView:self] began:false];
    }
}

- (void)finishTouches:(NSSet<UITouch*>*)touches {
    for (UITouch* touch in touches) {
        const auto it = _touches.find((__bridge const void*)touch);
        if (it == _touches.end()) {
            continue;
        }
        const size_t index = it->second;
        _touches.erase(it);
        // Another finger may still hold the same control.
        const bool still_held = std::any_of(_touches.begin(), _touches.end(),
                                            [index](const auto& entry) { return entry.second == index; });
        if (!still_held) {
            [self releaseControl:_controls[index]];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self finishTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self finishTouches:touches];
}

- (void)showMenu {
    UIViewController* presenter = self.window.rootViewController;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    UIAlertController* menu = [UIAlertController alertControllerWithTitle:@"Eglantine"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    const bool enabled = IosOverlay::Enabled();
    [menu addAction:[UIAlertAction actionWithTitle:enabled ? @"Hide touch controls" : @"Show touch controls"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction*) {
                                               IosOverlay::SetEnabled(!enabled);
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:IosOverlay::ShowFps() ? @"Hide FPS" : @"Show FPS"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction*) {
                                               IosOverlay::SetShowFps(!IosOverlay::ShowFps());
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Quit game"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction*) {
                                               SDL_Event quit{};
                                               quit.type = SDL_EVENT_QUIT;
                                               SDL_PushEvent(&quit);
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:menu animated:YES completion:nil];
}

@end

namespace IosOverlay {

void Attach(InputCommon::VirtualGamepad* gamepad) {
    RegisterDefaults();
    g_gamepad = gamepad;
    int count = 0;
    SDL_Window** windows = SDL_GetWindows(&count);
    if (windows == nullptr) {
        return;
    }
    SDL_Window* window = count > 0 ? windows[0] : nullptr;
    SDL_free(windows);
    if (window == nullptr) {
        return;
    }
    UIWindow* ui_window = (__bridge UIWindow*)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    UIView* host = ui_window.rootViewController.view;
    if (host == nil) {
        return;
    }
    EGOverlayView* overlay = [[EGOverlayView alloc] initWithFrame:host.bounds];
    [host addSubview:overlay];
}

bool Enabled() {
    RegisterDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:EnabledKey];
}

void SetEnabled(bool enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:EnabledKey];
}

float Opacity() {
    RegisterDefaults();
    return std::clamp([NSUserDefaults.standardUserDefaults floatForKey:OpacityKey], 0.15f, 1.0f);
}

void SetOpacity(float opacity) {
    [NSUserDefaults.standardUserDefaults setFloat:opacity forKey:OpacityKey];
}

bool Haptics() {
    RegisterDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:HapticsKey];
}

void SetHaptics(bool haptics) {
    [NSUserDefaults.standardUserDefaults setBool:haptics forKey:HapticsKey];
}

bool ShowFps() {
    RegisterDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:FpsKey];
}

void SetShowFps(bool show) {
    [NSUserDefaults.standardUserDefaults setBool:show forKey:FpsKey];
}

} // namespace IosOverlay
