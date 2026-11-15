//  TrollStore 形态的外壳 App：负责把 akundd 拉起来并看住它。
//  与 deb 形态的差别：这里没有 launchd，进程生命周期由本 App 的看门狗负责。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <Foundation/Foundation.h>

extern char **environ;

static NSString *const kPrefsRootless = @"/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist";
static NSString *const kPrefsLegacy   = @"/var/mobile/Library/Preferences/com.akun.bridge.plist";

@interface BridgeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) UITextField *deviceField;
@property (nonatomic, assign) pid_t childPid;
@property (nonatomic, assign) NSInteger restartCount;
@end

@implementation BridgeAppDelegate

#pragma mark - 配置读写

- (NSString *)prefsPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/jb/var/mobile/Library/Preferences";
    if ([fm fileExistsAtPath:@"/var/jb"]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        return kPrefsRootless;
    }
    dir = @"/var/mobile/Library/Preferences";
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return kPrefsLegacy;
}

- (NSDictionary *)loadPrefs {
    for (NSString *p in @[kPrefsRootless, kPrefsLegacy]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) { return d; }
    }
    return @{};
}

- (void)savePrefs {
    NSString *server = [(self.serverField.text ?: @"") stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *dev = [(self.deviceField.text ?: @"") stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 地址留空就写 auto，守护进程会自己广播找电脑
    NSDictionary *d = @{
        @"ServerBase": server.length ? server : @"auto",
        @"DeviceId": dev.length ? dev : @"dev001",
    };
    NSString *p = [self prefsPath];
    BOOL ok = [d writeToFile:p atomically:YES];
    NSLog(@"[app] 保存配置 %@ -> %d", p, ok);
}

#pragma mark - 拉起守护进程

- (NSString *)daemonPath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"akundd"];
}

- (void)spawnDaemon {
    if (self.childPid > 0) {
        int status = 0;
        pid_t r = waitpid(self.childPid, &status, WNOHANG);
        if (r == 0) { return; }  // 还活着
        NSLog(@"[app] akundd 已退出 status=%d，重启（第 %ld 次）", status, (long)++self.restartCount);
        self.childPid = 0;
    }

    NSString *path = [self daemonPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        self.statusLabel.text = @"akundd 缺失（打包不完整）";
        NSLog(@"[app] 找不到 %@", path);
        return;
    }
    chmod([path fileSystemRepresentation], 0755);

    const char *argv[] = { [path UTF8String], "-daemon", NULL };
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/tmp/akund-stdout.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/tmp/akund-stderr.log", O_WRONLY | O_CREAT | O_APPEND, 0644);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [path UTF8String], &actions, NULL, (char **)argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (rc == 0) {
        self.childPid = pid;
        self.statusLabel.text = [NSString stringWithFormat:@"akundd 运行中 pid=%d  重启 %ld", pid, (long)self.restartCount];
        NSLog(@"[app] 已拉起 akundd pid=%d", pid);
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"akundd 启动失败 rc=%d", rc];
        NSLog(@"[app] posix_spawn 失败 rc=%d", rc);
    }
}

#pragma mark - 生命周期

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    NSDictionary *prefs = [self loadPrefs];
    CGFloat w = vc.view.bounds.size.width;
    CGFloat y = 90;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 30)];
    title.text = @"AKUN WebRTC Bridge";
    title.font = [UIFont boldSystemFontOfSize:20];
    [vc.view addSubview:title];
    y += 44;

    self.serverField = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w - 40, 40)];
    self.serverField.placeholder = @"信令地址（留空=局域网自动发现）";
    self.serverField.text = prefs[@"ServerBase"] ?: @"";
    self.serverField.borderStyle = UITextBorderStyleRoundedRect;
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    [vc.view addSubview:self.serverField];
    y += 52;

    self.deviceField = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w - 40, 40)];
    self.deviceField.placeholder = @"设备 ID 如 dev001";
    self.deviceField.text = prefs[@"DeviceId"] ?: @"dev001";
    self.deviceField.borderStyle = UITextBorderStyleRoundedRect;
    self.deviceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.deviceField.autocorrectionType = UITextAutocorrectionTypeNo;
    [vc.view addSubview:self.deviceField];
    y += 52;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, y, w - 40, 44);
    [btn setTitle:@"保存并启动" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(onStart) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:btn];
    y += 56;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 80)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.text = @"未启动（地址留空则自动发现）";
    [vc.view addSubview:self.statusLabel];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 看门狗：每 5 秒检查一次子进程
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        [self spawnDaemon];
    }];
    [self spawnDaemon];
    return YES;
}

- (void)onStart {
    [self.serverField resignFirstResponder];
    [self.deviceField resignFirstResponder];
    [self savePrefs];
    if (self.childPid > 0) {
        kill(self.childPid, SIGTERM);
        self.childPid = 0;
        sleep(1);
    }
    self.restartCount = 0;
    [self spawnDaemon];
    self.statusLabel.text = [self.statusLabel.text stringByAppendingString:@"\n配置已保存，守护进程已重启"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([BridgeAppDelegate class]));
    }
}