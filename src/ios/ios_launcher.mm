// SPDX-FileCopyrightText: Copyright 2026 Eglantine Project
// SPDX-License-Identifier: GPL-3.0-or-later

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <os/proc.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <cmath>
#include <functional>
#include <memory>
#include <optional>

#include "common/settings.h"
#include "core/file_sys/nup_container.h"
#include "core/file_sys/vfs/vfs_real.h"
#include "core/loader/loader.h"
#include "dynarmic/interface/ios_jit.h"
#include "ios/ios_launcher.h"
#include "ios/ios_overlay.h"

namespace {

NSString* const BookmarksKey = @"EglantineLibraryBookmarks";

NSString* DocumentsPath() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString* UserPath() {
    return [DocumentsPath() stringByAppendingPathComponent:@"user"];
}

NSString* GamesPath() {
    return [DocumentsPath() stringByAppendingPathComponent:@"Games"];
}

NSString* KeysPath() {
    return [UserPath() stringByAppendingPathComponent:@"keys"];
}

NSString* FirmwarePath() {
    return [UserPath() stringByAppendingPathComponent:@"nand/system/Contents/registered"];
}

bool PathExists(NSString* path, BOOL* is_dir = nullptr) {
    BOOL dir = NO;
    const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
    if (is_dir != nullptr) {
        *is_dir = dir;
    }
    return exists;
}

void MakeDir(NSString* path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

bool g_first_launch = false;

void WriteReadme() {
    NSString* path = [DocumentsPath() stringByAppendingPathComponent:@"README.txt"];
    if (PathExists(path)) {
        return;
    }
    NSString* text =
        @"Eglantine for iOS\n"
         "=================\n\n"
         "Games/      Put games here: .nsp .xci .nsz .xcz .nca .nro .nup, or game folders\n"
         "            (a folder with exefs/main + romfs/, or with main + main.npdm).\n"
         "            You can also add games from anywhere with the + button.\n"
         "            .nup files and loose folders are already decrypted: no keys or\n"
         "            firmware needed. Encrypted dumps (NSP/XCI) still need user/keys.\n"
         "user/log/   Logs. Attach eden_log.txt and console.txt when reporting a problem.\n"
         "user/config/sdl3-config.ini\n"
         "            Settings. Edit with any text editor app.\n"
         "user/jit_mode.txt\n"
         "            Optional: \"txm\" or \"legacy\" to override the JIT method detection.\n\n"
         "JIT is required. Launch the app through StikDebug (or another JIT enabler); on iOS 26\n"
         "pick the universal script.\n";
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void ApplyJitOverride() {
    NSString* path = [UserPath() stringByAppendingPathComponent:@"jit_mode.txt"];
    NSString* mode = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (mode == nil) {
        return;
    }
    mode = [[mode stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    if ([mode isEqualToString:@"txm"]) {
        setenv("EGLANTINE_TXM", "1", 1);
    } else if ([mode isEqualToString:@"legacy"]) {
        setenv("EGLANTINE_TXM", "0", 1);
    }
}

UIViewController* TopViewController() {
    UIWindow* key = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow && !window.hidden) {
                key = window;
            }
        }
    }
    if (key == nil) {
        key = UIApplication.sharedApplication.windows.firstObject;
    }
    UIViewController* top = key.rootViewController;
    while (top.presentedViewController != nil) {
        top = top.presentedViewController;
    }
    return top;
}

void SpinUntil(BOOL (^done)(void)) {
    while (!done()) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    }
}

struct GameEntry {
    std::string title;
    std::string detail;
    std::string path;
};

bool IsGameExtension(NSString* ext) {
    static NSSet* const exts =
        [NSSet setWithArray:@[ @"nsp", @"xci", @"nsz", @"xcz", @"nca", @"nro", @"nso", @"nup", @"kip" ]];
    return [exts containsObject:ext.lowercaseString];
}

// A loose game folder: main next to main.npdm (an ExeFS), or exefs/ inside, or a split "00" file.
// Update folders (updates/<version>/exefs) become their own entries.
bool AddGameFolder(NSString* dir, std::vector<GameEntry>& out) {
    NSString* name = dir.lastPathComponent;
    bool found = false;
    if (PathExists([dir stringByAppendingPathComponent:@"main"])) {
        out.push_back({name.UTF8String, "Folder (ExeFS)", dir.UTF8String});
        found = true;
    }
    NSString* exefs = [dir stringByAppendingPathComponent:@"exefs"];
    if (PathExists([exefs stringByAppendingPathComponent:@"main"])) {
        out.push_back({name.UTF8String, "Folder", exefs.UTF8String});
        found = true;
    }
    NSString* updates = [dir stringByAppendingPathComponent:@"updates"];
    NSArray<NSString*>* versions =
        [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:updates error:nil]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString* version in versions) {
        NSString* update_exefs = [[updates stringByAppendingPathComponent:version]
            stringByAppendingPathComponent:@"exefs"];
        if (PathExists([update_exefs stringByAppendingPathComponent:@"main"])) {
            out.push_back({name.UTF8String,
                           std::string("Folder, update ") + version.UTF8String,
                           update_exefs.UTF8String});
            found = true;
        }
    }
    if (!found && PathExists([dir stringByAppendingPathComponent:@"00"])) {
        out.push_back({name.UTF8String, "Split file",
                       [dir stringByAppendingPathComponent:@"00"].UTF8String});
        found = true;
    }
    return found;
}

void ScanPath(NSString* path, int depth, std::vector<GameEntry>& out) {
    BOOL is_dir = NO;
    if (!PathExists(path, &is_dir)) {
        return;
    }
    if (!is_dir) {
        if (IsGameExtension(path.pathExtension)) {
            out.push_back({path.lastPathComponent.stringByDeletingPathExtension.UTF8String,
                           path.pathExtension.uppercaseString.UTF8String, path.UTF8String});
        }
        return;
    }
    if (AddGameFolder(path, out) || depth <= 0) {
        return;
    }
    NSArray<NSString*>* children =
        [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString* child in children) {
        if ([child hasPrefix:@"."]) {
            continue;
        }
        ScanPath([path stringByAppendingPathComponent:child], depth - 1, out);
    }
}

NSMutableArray<NSURL*>* g_accessed_urls = nil;

std::vector<NSString*> LibraryRoots() {
    std::vector<NSString*> roots{GamesPath()};
    if (g_accessed_urls == nil) {
        g_accessed_urls = [NSMutableArray array];
    }
    NSArray<NSData*>* bookmarks = [NSUserDefaults.standardUserDefaults arrayForKey:BookmarksKey];
    NSMutableArray<NSData*>* kept = [NSMutableArray array];
    for (NSData* bookmark in bookmarks) {
        BOOL stale = NO;
        NSURL* url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:nil];
        if (url == nil) {
            continue;
        }
        // Access stays open for the whole process: the game is read while it runs.
        if ([url startAccessingSecurityScopedResource]) {
            [g_accessed_urls addObject:url];
        }
        [kept addObject:bookmark];
        roots.push_back(url.path);
    }
    [NSUserDefaults.standardUserDefaults setObject:kept forKey:BookmarksKey];
    return roots;
}

std::vector<GameEntry> ScanLibrary() {
    std::vector<GameEntry> games;
    for (NSString* root : LibraryRoots()) {
        ScanPath(root, 3, games);
    }
    std::sort(games.begin(), games.end(), [](const GameEntry& a, const GameEntry& b) {
        return a.title == b.title ? a.detail < b.detail : a.title < b.title;
    });
    games.erase(std::unique(games.begin(), games.end(),
                            [](const GameEntry& a, const GameEntry& b) { return a.path == b.path; }),
                games.end());
    return games;
}

void AddBookmark(NSURL* url) {
    const BOOL accessing = [url startAccessingSecurityScopedResource];
    NSData* bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:nil];
    if (accessing) {
        [url stopAccessingSecurityScopedResource];
    }
    if (bookmark == nil) {
        return;
    }
    NSMutableArray<NSData*>* bookmarks =
        [[NSUserDefaults.standardUserDefaults arrayForKey:BookmarksKey] mutableCopy]
            ?: [NSMutableArray array];
    [bookmarks addObject:bookmark];
    [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:BookmarksKey];
}

NSUInteger CopyFirmware(NSURL* folder) {
    const BOOL accessing = [folder startAccessingSecurityScopedResource];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* dest = FirmwarePath();
    MakeDir(dest);
    NSUInteger copied = 0;
    NSDirectoryEnumerator<NSURL*>* it = [fm enumeratorAtURL:folder
                                 includingPropertiesForKeys:nil
                                                    options:0
                                               errorHandler:nil];
    for (NSURL* file in it) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"nca"]) {
            continue;
        }
        NSString* target = [dest stringByAppendingPathComponent:file.lastPathComponent];
        [fm removeItemAtPath:target error:nil];
        if ([fm copyItemAtPath:file.path toPath:target error:nil]) {
            ++copied;
        }
    }
    if (accessing) {
        [folder stopAccessingSecurityScopedResource];
    }
    return copied;
}

NSUInteger CopyKeys(NSArray<NSURL*>* files) {
    NSFileManager* fm = [NSFileManager defaultManager];
    MakeDir(KeysPath());
    NSUInteger copied = 0;
    for (NSURL* file in files) {
        const BOOL accessing = [file startAccessingSecurityScopedResource];
        NSString* target = [KeysPath() stringByAppendingPathComponent:file.lastPathComponent];
        [fm removeItemAtPath:target error:nil];
        if ([fm copyItemAtPath:file.path toPath:target error:nil]) {
            ++copied;
        }
        if (accessing) {
            [file stopAccessingSecurityScopedResource];
        }
    }
    return copied;
}

}  // namespace

// ---- Game metadata and artwork ----

namespace {

struct GameMeta {
    NSString* __strong title = nil;
    NSString* __strong detail = nil;
    UIImage* __strong art = nil;
    bool real_art = false;
};

NSString* StringFromBytes(const u8* data, size_t size) {
    size_t length = 0;
    while (length < size && data[length] != 0) {
        ++length;
    }
    if (length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding];
}

// control.nacp: 16 language entries of {name[0x200], publisher[0x100]}, American English first.
NSString* TitleFromNacp(NSData* nacp) {
    if (nacp.length < 0x300) {
        return nil;
    }
    const auto* bytes = static_cast<const u8*>(nacp.bytes);
    for (size_t language = 0; language < 16 && (language + 1) * 0x300 <= nacp.length; ++language) {
        if (NSString* name = StringFromBytes(bytes + language * 0x300, 0x200)) {
            return name;
        }
    }
    return nil;
}

// Loose dumps keep the control data next to (or above) exefs/: control/control.nacp and
// control/icon_<Language>.dat (a JPEG).
void ReadControlFolder(NSString* game_path, GameMeta& meta) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* dir = game_path;
    if ([dir.lastPathComponent isEqualToString:@"exefs"]) {
        dir = dir.stringByDeletingLastPathComponent;
    }
    for (NSString* candidate in @[ [dir stringByAppendingPathComponent:@"control"],
                                   [dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"control"],
                                   dir ]) {
        NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:candidate error:nil];
        if (files.count == 0) {
            continue;
        }
        if (meta.title == nil) {
            if (NSData* nacp = [NSData dataWithContentsOfFile:[candidate stringByAppendingPathComponent:@"control.nacp"]]) {
                meta.title = TitleFromNacp(nacp);
            }
        }
        if (meta.art == nil) {
            NSString* icon = nil;
            for (NSString* file in files) {
                if ([file hasPrefix:@"icon_"] && [file hasSuffix:@".dat"]) {
                    icon = [file isEqualToString:@"icon_AmericanEnglish.dat"] || icon == nil ? file : icon;
                }
            }
            if (icon != nil) {
                meta.art = [UIImage imageWithContentsOfFile:[candidate stringByAppendingPathComponent:icon]];
                meta.real_art = meta.art != nil;
            }
        }
        if (meta.title != nil && meta.art != nil) {
            return;
        }
    }
}

void ReadNup(NSString* path, GameMeta& meta) {
    const auto vfs = std::make_shared<FileSys::RealVfsFilesystem>();
    const auto file = vfs->OpenFile(path.fileSystemRepresentation, FileSys::OpenMode::Read);
    if (file == nullptr) {
        return;
    }
    FileSys::NupContainer nup{file};
    if (nup.GetStatus() != Loader::ResultStatus::Success) {
        return;
    }
    const auto& packages = nup.GetPackages();
    std::optional<size_t> base = nup.FindBasePackage();
    const auto update = nup.FindBestUpdatePackage();
    // Updates usually carry the newest name and icon.
    for (const auto index : {update, base}) {
        if (!index) {
            continue;
        }
        const auto& package = packages[*index];
        if (meta.title == nil) {
            std::string name = package.title_name;
            for (const auto& [language, localized] : package.localized_titles) {
                if (name.empty() || language == "AmericanEnglish" || language == "en-US") {
                    name = localized;
                }
            }
            if (!name.empty()) {
                meta.title = @(name.c_str());
            }
        }
        if (meta.art == nil && !package.icon.empty()) {
            NSData* data = [NSData dataWithBytes:package.icon.data() length:package.icon.size()];
            meta.art = [UIImage imageWithData:data];
            meta.real_art = meta.art != nil;
        }
        if (meta.detail == nil && !package.display_version.empty()) {
            meta.detail = [NSString stringWithFormat:@"NUP · v%s", package.display_version.c_str()];
        }
    }
}

// Cover for games without an icon: a gradient picked from the title, with its initials.
UIImage* GeneratedArt(NSString* title) {
    const NSUInteger hash = title.hash;
    const CGFloat hue = static_cast<CGFloat>(hash % 360) / 360.0;
    UIColor* top = [UIColor colorWithHue:hue saturation:0.65 brightness:0.85 alpha:1];
    UIColor* bottom = [UIColor colorWithHue:fmod(hue + 0.12, 1.0) saturation:0.8 brightness:0.45 alpha:1];
    NSMutableString* initials = [NSMutableString string];
    for (NSString* word in [title componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length > 0 && initials.length < 2) {
            [initials appendString:[[word substringToIndex:1] uppercaseString]];
        }
    }
    const CGSize size = CGSizeMake(256, 256);
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        NSArray* colors = @[ (__bridge id)top.CGColor, (__bridge id)bottom.CGColor ];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, nullptr);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(size.width, size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        NSDictionary* attrs = @{
            NSFontAttributeName : [UIFont systemFontOfSize:104 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName : [UIColor colorWithWhite:1 alpha:0.92],
        };
        const CGSize text = [initials sizeWithAttributes:attrs];
        [initials drawAtPoint:CGPointMake((size.width - text.width) / 2, (size.height - text.height) / 2)
               withAttributes:attrs];
    }];
}

GameMeta LoadMeta(const GameEntry& game) {
    GameMeta meta;
    NSString* path = @(game.path.c_str());
    @try {
        if ([path.pathExtension.lowercaseString isEqualToString:@"nup"]) {
            ReadNup(path, meta);
        } else {
            ReadControlFolder(path, meta);
        }
    } @catch (NSException*) {
    }
    if (meta.title == nil) {
        meta.title = @(game.title.c_str());
    }
    if (meta.detail == nil) {
        meta.detail = @(game.detail.c_str());
    }
    if (meta.art == nil) {
        meta.art = GeneratedArt(meta.title);
    }
    return meta;
}

} // namespace

@interface EGGameCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView* art;
@property(nonatomic, strong) UILabel* title;
@property(nonatomic, strong) UILabel* detail;
@property(nonatomic, copy) NSString* path;
@end

@implementation EGGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _art = [[UIImageView alloc] init];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.layer.cornerRadius = 16;
        _art.layer.cornerCurve = kCACornerCurveContinuous;
        _art.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _title = [[UILabel alloc] init];
        _title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _title.numberOfLines = 2;
        _detail = [[UILabel alloc] init];
        _detail.font = [UIFont systemFontOfSize:12];
        _detail.textColor = UIColor.secondaryLabelColor;
        for (UIView* view in @[ _art, _title, _detail ]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_art.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_art.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_art.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_art.heightAnchor constraintEqualToAnchor:_art.widthAnchor],
            [_title.topAnchor constraintEqualToAnchor:_art.bottomAnchor constant:6],
            [_title.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:2],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-2],
            [_detail.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:2],
            [_detail.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_detail.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
        ]];
    }
    return self;
}

@end

// ---- Settings ----

@interface EGSettingsController : UITableViewController
@property(nonatomic, copy) void (^onChange)(void);
@end

namespace {

struct SettingRow {
    NSString* __strong title = nil;
    NSString* __strong footer = nil;
    NSArray<NSString*>* __strong segments = nil;  // segmented control when set
    NSInteger (^get_index)(void) = nil;
    void (^set_index)(NSInteger) = nil;
    BOOL (^get_bool)(void) = nil;  // switch when set
    void (^set_bool)(BOOL) = nil;
    float (^get_float)(void) = nil;  // slider when set
    void (^set_float)(float) = nil;
    NSString* __strong value = nil;  // read-only text otherwise
};

struct SettingSection {
    NSString* __strong title = nil;
    NSString* __strong footer = nil;
    std::vector<SettingRow> rows;
};

template <typename E>
NSInteger IndexOf(const std::vector<E>& values, E value) {
    const auto it = std::find(values.begin(), values.end(), value);
    return it == values.end() ? 0 : static_cast<NSInteger>(it - values.begin());
}

} // namespace

@implementation EGSettingsController {
    std::vector<SettingSection> _sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];
    [self buildSections];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)changed {
    if (self.onChange != nil) {
        self.onChange();
    }
}

- (void)buildSections {
    using namespace Settings;
    static const std::vector<ResolutionSetup> resolutions{ResolutionSetup::Res1_2X, ResolutionSetup::Res3_4X,
                                                         ResolutionSetup::Res1X, ResolutionSetup::Res3_2X,
                                                         ResolutionSetup::Res2X};
    static const std::vector<AntiAliasing> aa{AntiAliasing::None, AntiAliasing::Fxaa, AntiAliasing::Smaa};
    static const std::vector<CpuAccuracy> cpu{CpuAccuracy::Auto, CpuAccuracy::Accurate, CpuAccuracy::Unsafe};

    SettingSection graphics{@"Graphics", @"Lower resolution and Handheld mode are the biggest speed-ups on a phone. "
                                          @"Async shaders trade brief missing effects for less stutter."};
    graphics.rows.push_back({.title = @"Resolution",
                             .segments = @[ @"0.5×", @"0.75×", @"1×", @"1.5×", @"2×" ],
                             .get_index = ^NSInteger { return IndexOf(resolutions, values.resolution_setup.GetValue()); },
                             .set_index = ^(NSInteger i) { values.resolution_setup.SetValue(resolutions[i]); }});
    graphics.rows.push_back({.title = @"Console mode",
                             .segments = @[ @"Handheld", @"Docked" ],
                             .get_index = ^NSInteger { return values.use_docked_mode.GetValue() == ConsoleMode::Docked ? 1 : 0; },
                             .set_index = ^(NSInteger i) { values.use_docked_mode.SetValue(i == 1 ? ConsoleMode::Docked : ConsoleMode::Handheld); }});
    graphics.rows.push_back({.title = @"GPU accuracy",
                             .segments = @[ @"Low (faster)", @"High" ],
                             .get_index = ^NSInteger { return values.gpu_accuracy.GetValue() == GpuAccuracy::High ? 1 : 0; },
                             .set_index = ^(NSInteger i) { values.gpu_accuracy.SetValue(i == 1 ? GpuAccuracy::High : GpuAccuracy::Low); }});
    graphics.rows.push_back({.title = @"Anti-aliasing",
                             .segments = @[ @"Off", @"FXAA", @"SMAA" ],
                             .get_index = ^NSInteger { return IndexOf(aa, values.anti_aliasing.GetValue()); },
                             .set_index = ^(NSInteger i) { values.anti_aliasing.SetValue(aa[i]); }});
    graphics.rows.push_back({.title = @"Asynchronous shaders",
                             .get_bool = ^BOOL { return values.use_asynchronous_shaders.GetValue(); },
                             .set_bool = ^(BOOL on) { values.use_asynchronous_shaders.SetValue(on); }});
    graphics.rows.push_back({.title = @"Disk shader cache",
                             .get_bool = ^BOOL { return values.use_disk_shader_cache.GetValue(); },
                             .set_bool = ^(BOOL on) { values.use_disk_shader_cache.SetValue(on); }});

    SettingSection system{@"System", @"Unsafe CPU accuracy is faster and works for most games."};
    system.rows.push_back({.title = @"CPU accuracy",
                           .segments = @[ @"Auto", @"Accurate", @"Unsafe" ],
                           .get_index = ^NSInteger { return IndexOf(cpu, values.cpu_accuracy.GetValue()); },
                           .set_index = ^(NSInteger i) { values.cpu_accuracy.SetValue(cpu[i]); }});
    system.rows.push_back({.title = @"Multicore CPU",
                           .get_bool = ^BOOL { return values.use_multi_core.GetValue(); },
                           .set_bool = ^(BOOL on) { values.use_multi_core.SetValue(on); }});
    system.rows.push_back({.title = @"Limit speed to 100%",
                           .get_bool = ^BOOL { return values.use_speed_limit.GetValue(); },
                           .set_bool = ^(BOOL on) { values.use_speed_limit.SetValue(on); }});

    SettingSection audio{@"Audio", nil};
    audio.rows.push_back({.title = @"Mute",
                          .get_bool = ^BOOL { return values.audio_muted.GetValue(); },
                          .set_bool = ^(BOOL on) { values.audio_muted.SetValue(on); }});
    audio.rows.push_back({.title = @"Volume",
                          .get_float = ^float { return values.volume.GetValue() / 100.0f; },
                          .set_float = ^(float v) { values.volume.SetValue(static_cast<u8>(std::lround(v * 100))); }});

    SettingSection controls{@"Touch controls", @"The on-screen controller hides itself while a game controller is connected. "
                                               @"Tap ≡ in-game for the menu."};
    controls.rows.push_back({.title = @"Show touch controls",
                             .get_bool = ^BOOL { return IosOverlay::Enabled(); },
                             .set_bool = ^(BOOL on) { IosOverlay::SetEnabled(on); }});
    controls.rows.push_back({.title = @"Opacity",
                             .get_float = ^float { return IosOverlay::Opacity(); },
                             .set_float = ^(float v) { IosOverlay::SetOpacity(std::max(0.15f, v)); }});
    controls.rows.push_back({.title = @"Haptic feedback",
                             .get_bool = ^BOOL { return IosOverlay::Haptics(); },
                             .set_bool = ^(BOOL on) { IosOverlay::SetHaptics(on); }});
    controls.rows.push_back({.title = @"Show FPS",
                             .get_bool = ^BOOL { return IosOverlay::ShowFps(); },
                             .set_bool = ^(BOOL on) { IosOverlay::SetShowFps(on); }});

    SettingSection about{@"About", nil};
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    about.rows.push_back({.title = @"Version",
                          .value = [NSString stringWithFormat:@"%@ (build %@)", info[@"CFBundleShortVersionString"],
                                                              info[@"CFBundleVersion"]]});
    about.rows.push_back({.title = @"JIT", .value = @(IosLauncher::JitStatus().c_str())});
    about.rows.push_back({.title = @"Memory available",
                          .value = [NSString stringWithFormat:@"%.1f GiB",
                                                              os_proc_available_memory() / (1024.0 * 1024.0 * 1024.0)]});

    _sections = {graphics, system, audio, controls, about};
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return static_cast<NSInteger>(_sections.size());
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section].title;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[section].footer;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return static_cast<NSInteger>(_sections[section].rows.size());
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    const SettingRow& row = _sections[indexPath.section].rows[indexPath.row];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row.title;
    if (row.segments != nil) {
        UISegmentedControl* control = [[UISegmentedControl alloc] initWithItems:row.segments];
        control.selectedSegmentIndex = row.get_index();
        void (^set)(NSInteger) = row.set_index;
        __weak EGSettingsController* weak_self = self;
        [control addAction:[UIAction actionWithHandler:^(UIAction* action) {
                     set(((UISegmentedControl*)action.sender).selectedSegmentIndex);
                     [weak_self changed];
                 }]
          forControlEvents:UIControlEventValueChanged];
        [control sizeToFit];
        const CGFloat max_width = tableView.bounds.size.width * 0.62;
        if (control.frame.size.width > max_width) {
            control.frame = CGRectMake(0, 0, max_width, control.frame.size.height);
            control.apportionsSegmentWidthsByContent = YES;
        }
        cell.accessoryView = control;
    } else if (row.get_bool != nil) {
        UISwitch* toggle = [[UISwitch alloc] init];
        toggle.on = row.get_bool();
        void (^set)(BOOL) = row.set_bool;
        __weak EGSettingsController* weak_self = self;
        [toggle addAction:[UIAction actionWithHandler:^(UIAction* action) {
                    set(((UISwitch*)action.sender).isOn);
                    [weak_self changed];
                }]
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (row.get_float != nil) {
        UISlider* slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
        slider.value = row.get_float();
        void (^set)(float) = row.set_float;
        __weak EGSettingsController* weak_self = self;
        [slider addAction:[UIAction actionWithHandler:^(UIAction* action) {
                    set(((UISlider*)action.sender).value);
                }]
         forControlEvents:UIControlEventValueChanged];
        [slider addAction:[UIAction actionWithHandler:^(UIAction*) { [weak_self changed]; }]
         forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        cell.accessoryView = slider;
    } else {
        cell.detailTextLabel.text = row.value;
        cell.detailTextLabel.numberOfLines = 2;
    }
    return cell;
}

@end

// ---- Library ----

enum class PickerMode { Games, Keys, Firmware };

@interface EGLibraryController : UICollectionViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^onPick)(NSString* path);
@property(nonatomic, copy) void (^onSettingsChanged)(void);
@end

@implementation EGLibraryController {
    std::vector<GameEntry> _games;
    NSCache<NSString*, id>* _meta_cache;
    PickerMode _pickerMode;
    UILabel* _empty;
}

+ (UICollectionViewLayout*)gridLayout {
    return [[UICollectionViewCompositionalLayout alloc]
        initWithSectionProvider:^NSCollectionLayoutSection*(NSInteger, id<NSCollectionLayoutEnvironment> env) {
            const CGFloat width = env.container.effectiveContentSize.width;
            const NSInteger columns = std::max<NSInteger>(2, static_cast<NSInteger>(width / 150));
            NSCollectionLayoutSize* item_size =
                [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0 / columns]
                                               heightDimension:[NSCollectionLayoutDimension estimatedDimension:width / columns + 56]];
            NSCollectionLayoutItem* item = [NSCollectionLayoutItem itemWithLayoutSize:item_size];
            item.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
            NSCollectionLayoutSize* group_size =
                [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                               heightDimension:[NSCollectionLayoutDimension estimatedDimension:width / columns + 56]];
            NSCollectionLayoutGroup* group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:group_size
                                                                                     repeatingSubitem:item
                                                                                                count:columns];
            NSCollectionLayoutSection* section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 24, 12);
            return section;
        }];
}

- (instancetype)init {
    return [super initWithCollectionViewLayout:[EGLibraryController gridLayout]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _meta_cache = [[NSCache alloc] init];
    self.title = @"Eglantine";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:EGGameCell.class forCellWithReuseIdentifier:@"game"];
    UIRefreshControl* refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(pulledToRefresh:) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = refresh;

    UIAction* add = [UIAction actionWithTitle:@"Add Games or Folder"
                                        image:[UIImage systemImageNamed:@"plus"]
                                   identifier:nil
                                      handler:^(UIAction*) { [self presentPicker:PickerMode::Games]; }];
    // Only encrypted dumps (NSP/XCI/NSZ/XCZ) use these; .nup and loose folders never do.
    UIAction* keys = [UIAction actionWithTitle:@"Import Keys (encrypted dumps only)"
                                         image:[UIImage systemImageNamed:@"key"]
                                    identifier:nil
                                       handler:^(UIAction*) { [self presentPicker:PickerMode::Keys]; }];
    UIAction* firmware = [UIAction actionWithTitle:@"Import Firmware (optional)"
                                             image:[UIImage systemImageNamed:@"cpu"]
                                        identifier:nil
                                           handler:^(UIAction*) { [self presentPicker:PickerMode::Firmware]; }];
    UIAction* reset = [UIAction actionWithTitle:@"Forget Added Locations"
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(UIAction*) {
                                            [NSUserDefaults.standardUserDefaults removeObjectForKey:BookmarksKey];
                                            [self reload];
                                        }];
    reset.attributes = UIMenuElementAttributesDestructive;
    UIBarButtonItem* more =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"]
                                          menu:[UIMenu menuWithChildren:@[ add, keys, firmware, reset ]]];
    UIBarButtonItem* settings =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showSettings)];
    self.navigationItem.rightBarButtonItems = @[ more, settings ];
    self.navigationItem.prompt = IosLauncher::JitAvailable()
                                     ? nil
                                     : @"JIT is off: relaunch through StikDebug to play";

    _empty = [[UILabel alloc] init];
    _empty.text = @"No games yet.\nCopy them into Eglantine › Games in the Files app,\nor tap ⊕ to add a folder.";
    _empty.numberOfLines = 0;
    _empty.textAlignment = NSTextAlignmentCenter;
    _empty.textColor = UIColor.secondaryLabelColor;
    self.collectionView.backgroundView = _empty;
    [self reload];
}

- (void)pulledToRefresh:(UIRefreshControl*)sender {
    [_meta_cache removeAllObjects];
    [self reload];
    [sender endRefreshing];
}

- (void)reload {
    _games = ScanLibrary();
    _empty.hidden = !_games.empty();
    [self.collectionView reloadData];
}

- (void)showSettings {
    EGSettingsController* settings = [[EGSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    settings.onChange = self.onSettingsChanged;
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:settings];
    [self presentViewController:nav animated:YES completion:nil];
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section {
    return static_cast<NSInteger>(_games.size());
}

- (void)applyMeta:(NSDictionary*)meta toCell:(EGGameCell*)cell {
    cell.title.text = meta[@"title"];
    cell.detail.text = meta[@"detail"];
    cell.art.image = meta[@"art"];
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView
                 cellForItemAtIndexPath:(NSIndexPath*)indexPath {
    EGGameCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:indexPath];
    const GameEntry game = _games[indexPath.item];
    NSString* path = @(game.path.c_str());
    cell.path = path;
    if (NSDictionary* cached = [_meta_cache objectForKey:path]) {
        [self applyMeta:cached toCell:cell];
        return cell;
    }
    cell.title.text = @(game.title.c_str());
    cell.detail.text = @(game.detail.c_str());
    cell.art.image = nil;
    __weak EGLibraryController* weak_self = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const GameMeta meta = LoadMeta(game);
        NSDictionary* result = @{@"title" : meta.title, @"detail" : meta.detail, @"art" : meta.art};
        dispatch_async(dispatch_get_main_queue(), ^{
            EGLibraryController* strong = weak_self;
            if (strong == nil) {
                return;
            }
            [strong->_meta_cache setObject:result forKey:path];
            if ([cell.path isEqualToString:path]) {
                [strong applyMeta:result toCell:cell];
            }
        });
    });
    return cell;
}

- (void)collectionView:(UICollectionView*)collectionView didSelectItemAtIndexPath:(NSIndexPath*)indexPath {
    if (self.onPick != nil) {
        self.onPick(@(_games[indexPath.item].path.c_str()));
    }
}

- (void)presentPicker:(PickerMode)mode {
    _pickerMode = mode;
    NSArray<UTType*>* types = nil;
    switch (mode) {
    case PickerMode::Games:
        types = @[ UTTypeFolder, UTTypeItem ];
        break;
    case PickerMode::Keys:
        types = @[ UTTypeItem ];
        break;
    case PickerMode::Firmware:
        types = @[ UTTypeFolder ];
        break;
    }
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = mode != PickerMode::Firmware;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    switch (_pickerMode) {
    case PickerMode::Games:
        for (NSURL* url in urls) {
            AddBookmark(url);
        }
        [self reload];
        break;
    case PickerMode::Keys:
        [self showMessage:[NSString stringWithFormat:@"Copied %lu key file(s).", (unsigned long)CopyKeys(urls)]];
        break;
    case PickerMode::Firmware: {
        const NSUInteger count = urls.firstObject != nil ? CopyFirmware(urls.firstObject) : 0;
        [self showMessage:[NSString stringWithFormat:@"Copied %lu firmware file(s).", (unsigned long)count]];
        break;
    }
    }
}

- (void)showMessage:(NSString*)message {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

namespace IosLauncher {

void PrepareEnvironment() {
    NSString* documents = DocumentsPath();
    g_first_launch = !PathExists(UserPath());
    MakeDir(UserPath());
    MakeDir(KeysPath());
    MakeDir(FirmwarePath());
    MakeDir(GamesPath());
    WriteReadme();
    // Eden picks "<cwd>/user" as a portable user folder, which puts saves, keys, config and logs
    // in Documents where the Files app can reach them.
    chdir(documents.fileSystemRepresentation);

    // stderr has nowhere to go on a phone. MoltenVK writes its errors there (the Metal compiler
    // message behind a failed pipeline), as does the JIT setup, so keep them next to Eden's log.
    NSString* log_dir = [UserPath() stringByAppendingPathComponent:@"log"];
    MakeDir(log_dir);
    NSString* console = [log_dir stringByAppendingPathComponent:@"console.txt"];
    if (freopen(console.fileSystemRepresentation, "w", stderr) != nullptr) {
        setvbuf(stderr, nullptr, _IONBF, 0);
    }
    setenv("MVK_CONFIG_LOG_LEVEL", "2", 0);

    ApplyJitOverride();
    Dynarmic::IosJit::Initialize();

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification*) {
                    std::fprintf(stderr, "[ios] memory warning, %llu MiB available\n",
                                 static_cast<unsigned long long>(os_proc_available_memory() >> 20));
                }];
}

bool IsFirstLaunch() {
    return g_first_launch;
}

std::string PickGame(std::function<void()> save_settings) {
    __block bool done = false;
    __block std::string result;

    UIWindow* window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
            break;
        }
    }
    EGLibraryController* library = [[EGLibraryController alloc] init];
    library.onPick = ^(NSString* path) {
        result = path.UTF8String;
        done = true;
    };
    auto save = std::make_shared<std::function<void()>>(std::move(save_settings));
    library.onSettingsChanged = ^{
        if (*save) {
            (*save)();
        }
    };
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:library];
    window.windowLevel = UIWindowLevelNormal + 1;
    [window makeKeyAndVisible];

    SpinUntil(^BOOL { return done; });

    window.hidden = YES;
    window.rootViewController = nil;
    return result;
}

void ShowAlert(const std::string& title, const std::string& message) {
    std::fprintf(stderr, "[ios] %s: %s\n", title.c_str(), message.c_str());
    __block bool dismissed = false;
    UIViewController* presenter = TopViewController();
    UIWindow* own_window = nil;
    if (presenter == nil) {
        own_window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        own_window.rootViewController = [UIViewController new];
        [own_window makeKeyAndVisible];
        presenter = own_window.rootViewController;
    }
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@(title.c_str())
                                                                   message:@(message.c_str())
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction*) { dismissed = true; }]];
    [presenter presentViewController:alert animated:YES completion:nil];
    SpinUntil(^BOOL { return dismissed; });
    own_window.hidden = YES;
}

std::string JitStatus() {
    return Dynarmic::IosJit::StatusString(Dynarmic::IosJit::GetStatus());
}

bool JitAvailable() {
    return Dynarmic::IosJit::IsAvailable();
}

}  // namespace IosLauncher
