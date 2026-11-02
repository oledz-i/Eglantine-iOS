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

#include "dynarmic/interface/ios_jit.h"
#include "ios/ios_launcher.h"

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
         "user/log/   Logs. Attach eden_log.txt when reporting a problem.\n"
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

enum class PickerMode { Games, Keys, Firmware };

@interface EGLibraryController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^onPick)(NSString* path);
@end

@implementation EGLibraryController {
    std::vector<GameEntry> _games;
    PickerMode _pickerMode;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Eglantine";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"status"];
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
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                          menu:[UIMenu menuWithChildren:@[ add, keys, firmware, reset ]]];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reload)];
    [self reload];
}

- (void)reload {
    _games = ScanLibrary();
    [self.tableView reloadData];
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
    case PickerMode::Keys: {
        const NSUInteger count = CopyKeys(urls);
        [self showMessage:[NSString stringWithFormat:@"Copied %lu key file(s).", (unsigned long)count]];
        [self.tableView reloadData];
        break;
    }
    case PickerMode::Firmware: {
        const NSUInteger count = urls.firstObject != nil ? CopyFirmware(urls.firstObject) : 0;
        [self showMessage:[NSString stringWithFormat:@"Copied %lu firmware file(s).", (unsigned long)count]];
        [self.tableView reloadData];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Status" : @"Games";
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1 && _games.empty()) {
        return @"No games found. Copy games into Eglantine/Games in the Files app, or add a location with the menu.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : static_cast<NSInteger>(_games.size());
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        switch (indexPath.row) {
        case 0:
            cell.textLabel.text = @"JIT";
            cell.detailTextLabel.text = @(IosLauncher::JitStatus().c_str());
            cell.imageView.image = [UIImage systemImageNamed:IosLauncher::JitAvailable() ? @"bolt.fill" : @"bolt.slash"];
            break;
        case 1: {
            const double free_gib = static_cast<double>(os_proc_available_memory()) / (1024.0 * 1024.0 * 1024.0);
            cell.textLabel.text = @"Memory";
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%.1f GiB available to the app", free_gib];
            cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
            break;
        }
        }
        return cell;
    }
    const GameEntry& game = _games[indexPath.row];
    cell.textLabel.text = @(game.title.c_str());
    cell.detailTextLabel.text = @(game.detail.c_str());
    cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.onPick == nil) {
        return;
    }
    self.onPick(@(_games[indexPath.row].path.c_str()));
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

std::string PickGame() {
    __block bool done = false;
    __block std::string result;

    UIWindow* window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
            break;
        }
    }
    EGLibraryController* library = [[EGLibraryController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    library.onPick = ^(NSString* path) {
        result = path.UTF8String;
        done = true;
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
