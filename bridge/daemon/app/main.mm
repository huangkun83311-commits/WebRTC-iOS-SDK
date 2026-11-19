//  TrollStore 形态的外壳 App。
//  两层职责：
//   1) 首次运行就把 akundd 注册成系统 LaunchDaemon —— 之后开机自启、不打开 App 也在跑
//   2) 看板：设备名 / UDID / 本机 IP / 型号 / daemon 状态 / 重启服务 / 连接配置 / 实时日志
//  TrollStore 装的 App 带 platform-application entitlement，写 /var/jb 与调 launchctl 都可用；
//  真被拒就退化成"前台看门狗"模式，UI 会如实显示当前是哪种模式，不假装。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <signal.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

extern char **environ;

static NSString *const kLabel         = @"com.akun.akund";
static NSString *const kPrefsRootless = @"/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist";
static NSString *const kPrefsLegacy   = @"/var/mobile/Library/Preferences/com.akun.bridge.plist";
static NSString *const kErrLog        = @"/tmp/akund-stderr.log";
static NSString *const kOutLog        = @"/tmp/akund-stdout.log";

#define COL_BG      [UIColor colorWithRed:0.055 green:0.067 blue:0.086 alpha:1.0]
#define COL_CARD    [UIColor colorWithRed:0.102 green:0.122 blue:0.153 alpha:1.0]
#define COL_LINE    [UIColor colorWithRed:0.165 green:0.192 blue:0.235 alpha:1.0]
#define COL_TEXT    [UIColor colorWithRed:0.918 green:0.933 blue:0.953 alpha:1.0]
#define COL_SUB     [UIColor colorWithRed:0.541 green:0.576 blue:0.631 alpha:1.0]
#define COL_ACCENT  [UIColor colorWithRed:0.184 green:0.506 blue:0.969 alpha:1.0]
#define COL_OK      [UIColor colorWithRed:0.247 green:0.725 blue:0.314 alpha:1.0]
#define COL_WARN    [UIColor colorWithRed:0.961 green:0.651 blue:0.137 alpha:1.0]
#define COL_BAD     [UIColor colorWithRed:0.973 green:0.318 blue:0.286 alpha:1.0]

#pragma mark - 系统工具

static NSString *jbRoot(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // rootful / rootless：/var/jb 是真实目录
        if ([fm fileExistsAtPath:@"/var/jb"]) { cached = @"/var/jb"; return; }
        // roothide（Dopamine + RootHide）：越狱根藏在 /var/containers/Bundle/Application/.jbroot-XXXX，
        // 后缀随机只能扫；扫到就当路径前缀用，扫不到按根算
        NSArray<NSString *> *dirs = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *d in dirs) {
            if (![d hasPrefix:@".jbroot-"]) continue;
            NSString *p = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:d];
            if ([fm isExecutableFileAtPath:[p stringByAppendingPathComponent:@"usr/bin/launchctl"]]) {
                cached = p; return;
            }
        }
        cached = @"";
    });
    return cached;
}

static NSString *jbPath(NSString *p) {
    NSString *r = jbRoot();
    return r.length ? [r stringByAppendingPathComponent:p] : p;
}

static NSString *runCmd(NSString *exe, NSArray<NSString *> *args) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:exe]) return @"";
    NSString *tmp = [NSString stringWithFormat:@"/tmp/akun-cmd-%u.log", (unsigned)arc4random()];
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, tmp.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, tmp.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);

    char **argv = (char **)calloc(args.count + 2, sizeof(char *));
    argv[0] = (char *)exe.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = (char *)args[i].UTF8String;
    argv[args.count + 1] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.UTF8String, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    if (rc == 0) { int st = 0; waitpid(pid, &st, 0); }

    NSString *out = [NSString stringWithContentsOfFile:tmp encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return out;
}

static NSString *mgString(NSString *key) {
    if (!key.length) return nil;
    typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef);
    static MGCopyAnswerFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (h) fn = (MGCopyAnswerFn)dlsym(h, "MGCopyAnswer");
    });
    if (!fn) return nil;
    CFTypeRef v = fn((__bridge CFStringRef)key);
    if (!v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        s = (__bridge_transfer NSString *)v;
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        s = [(__bridge_transfer NSNumber *)v stringValue];
    } else {
        CFRelease(v);
    }
    return s.length ? s : nil;
}

static NSString *localIPv4(void) {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return @"未知";
    NSString *best = nil, *fallback = nil;
    for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:a->ifa_name] ?: @"";
        if ([name isEqualToString:@"lo0"]) continue;
        char buf[64] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, buf, sizeof(buf));
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([name isEqualToString:@"en0"]) best = ip;
        else if (!fallback) fallback = ip;
    }
    freeifaddrs(addrs);
    return best ?: (fallback ?: @"未联网");
}

#pragma mark - App

@interface BridgeAppDelegate : UIResponder <UIApplicationDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, strong) UILabel *statusDot, *statusText;
@property (nonatomic, strong) UILabel *nameValue, *udidValue, *ipValue, *modelValue, *pidValue;
@property (nonatomic, strong) UILabel *modeLabel;
@property (nonatomic, strong) UITextField *serverField, *deviceField;
@property (nonatomic, strong) UIButton *restartBtn, *saveBtn;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, assign) pid_t childPid;
@property (nonatomic, assign) BOOL usingLaunchd;
@end

@implementation BridgeAppDelegate

#pragma mark 配置

- (NSString *)prefsPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = jbPath(@"/var/mobile/Library/Preferences");
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"com.akun.akund.plist"];
}

- (NSDictionary *)loadPrefs {
    for (NSString *p in @[kPrefsRootless, kPrefsLegacy]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) return d;
    }
    return @{};
}

- (void)savePrefs:(BOOL)thenRestart {
    NSString *server = [(self.serverField.text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *dev = [(self.deviceField.text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *d = @{ @"ServerBase": server.length ? server : @"auto",
                         @"DeviceId": dev.length ? dev : @"dev001" };
    BOOL ok = [d writeToFile:[self prefsPath] atomically:YES];
    [self toast:ok ? @"配置已保存" : @"配置写入失败"];
    if (thenRestart) [self restartService];
}

#pragma mark 自启

- (NSString *)bundleDaemonPath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"akundd"];
}
- (NSString *)installedDaemonPath { return jbPath(@"/usr/bin/akund"); }

- (BOOL)installDaemonBinary {
    NSString *src = [self bundleDaemonPath];
    NSString *dst = [self installedDaemonPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSNumber *srcSize = [[fm attributesOfItemAtPath:src error:nil] objectForKey:NSFileSize];
    NSNumber *dstSize = [[fm attributesOfItemAtPath:dst error:nil] objectForKey:NSFileSize];
    if (dstSize && srcSize && [dstSize isEqualToNumber:srcSize]) return YES;
    [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    BOOL ok = [fm copyItemAtPath:src toPath:dst error:&err];
    chmod(dst.UTF8String, 0755);
    NSLog(@"[app] 安装守护二进制 %@ -> %d %@", dst, ok, err.localizedDescription);
    return ok;
}

- (BOOL)writeLaunchDaemonPlist {
    NSString *plist = jbPath(@"/Library/LaunchDaemons/com.akun.akund.plist");
    NSDictionary *cfg = @{
        @"Label": kLabel,
        @"ProgramArguments": @[ [self installedDaemonPath], @"-daemon" ],
        @"RunAtLoad": @YES,
        @"KeepAlive": @{ @"SuccessfulExit": @NO },
        @"ThrottleInterval": @10,
        @"ProcessType": @"Background",
        @"StandardOutPath": kOutLog,
        @"StandardErrorPath": kErrLog,
    };
    BOOL wrote = [cfg writeToFile:@"/tmp/akun-launchd-src.plist" atomically:YES];
    if (!wrote) return NO;
    runCmd(jbPath(@"/usr/bin/plutil"), @[@"-convert", @"binary1", @"/tmp/akun-launchd-src.plist", @"-o", plist]);
    BOOL ok = [[NSFileManager defaultManager] fileExistsAtPath:plist];
    if (ok) chmod(plist.UTF8String, 0644);
    NSLog(@"[app] 写 LaunchDaemon %@ -> %d", plist, ok);
    return ok;
}

- (BOOL)daemonAlive {
    // 前台看门狗：自己拉起来的子进程活着就算活着（无 root 的纯 tipa 形态只能走这条）
    if (self.childPid > 0) {
        int st = 0;
        if (waitpid(self.childPid, &st, WNOHANG) == 0) return YES;
        self.childPid = 0;
    }
    // 域要全查：deb 的 postinst 注册在 system；TrollStore 的 App 没有 root，只能注册进 user/<uid>
    NSString *lc = jbPath(@"/usr/bin/launchctl");
    NSArray<NSString *> *scopes = @[ @"system",
                                     [NSString stringWithFormat:@"user/%d", getuid()],
                                     [NSString stringWithFormat:@"gui/%d", getuid()] ];
    for (NSString *sc in scopes) {
        NSString *out = runCmd(lc, @[@"print", [NSString stringWithFormat:@"%@/%@", sc, kLabel]]);
        if (out.length && [out containsString:@"state = running"]) return YES;
    }
    // launchctl 查不到时按端口再判一次（19949 是 rootd/dpkgd 的口子，daemon 在跑就一定在听）
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_in a; memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_port = htons(19949);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        BOOL up = (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
        close(fd);
        if (up) return YES;
    }
    // 没注册 launchd 时退回端口探测
    NSString *lsof = jbPath(@"/usr/bin/lsof");
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:lsof]) {
        NSString *s = runCmd(lsof, @[@"-iTCP:19949", @"-sTCP:LISTEN", @"-n", @"-P"]);
        if (s.length) return YES;
    }
    return NO;
}

- (void)ensureAutoStart {
    NSString *lc = jbPath(@"/usr/bin/launchctl");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:lc]) {
        self.usingLaunchd = NO;
        self.modeLabel.text = @"模式：前台看门狗（本机没有 launchctl）";
        return;
    }
    // 已经有 system 域的 daemon 在跑（deb 的 postinst 注册的），就别再抢：直接认这个
    NSString *sysOut = runCmd(lc, @[@"print", [NSString stringWithFormat:@"system/%@", kLabel]]);
    if (sysOut.length && [sysOut containsString:@"state = running"]) {
        self.usingLaunchd = YES;
        self.modeLabel.text = @"模式：系统守护进程（开机自启，无需打开 App）";
        return;
    }

    NSString *daemonDir = jbPath(@"/Library/LaunchDaemons");
    [[NSFileManager defaultManager] createDirectoryAtPath:daemonDir withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL binaryOK = [self installDaemonBinary];
    BOOL plistOK  = [self writeLaunchDaemonPlist];
    if (!binaryOK || !plistOK) {
        // 无 root 写不进越狱根（/usr/bin、/Library/LaunchDaemons），但 TrollStore App 的容器
        // 是 Unrestricted，能写 /var/mobile/Library/LaunchAgents —— 那是 mobile 用户的
        // launchd（gui/<uid> 域）扫描目录：注册进去一样是"开机自启、不用打开 App"，
        // 区别只是身份是 mobile 不是 root（抓屏/注入 mobile 已经够用，实测 30fps 正常）。
        NSString *agentPlist = @"/var/mobile/Library/LaunchAgents/com.akun.akund.plist";
        NSString *bundleDaemon = [self bundleDaemonPath];
        NSDictionary *cfg = @{
            @"Label": kLabel,
            @"ProgramArguments": @[ bundleDaemon, @"-daemon" ],
            @"RunAtLoad": @YES,
            @"KeepAlive": @{ @"SuccessfulExit": @NO },
            @"ThrottleInterval": @10,
            @"ProcessType": @"Background",
            @"StandardOutPath": kOutLog,
            @"StandardErrorPath": kErrLog,
        };
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/LaunchAgents"
                                   withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL agentOK = [cfg writeToFile:agentPlist atomically:YES];
        if (agentOK) chmod(agentPlist.UTF8String, 0644);
        if (agentOK) {
            NSString *scope = [NSString stringWithFormat:@"gui/%d", getuid()];
            runCmd(lc, @[@"bootout", [NSString stringWithFormat:@"%@/%@", scope, kLabel]]);
            NSString *o2 = runCmd(lc, @[@"bootstrap", scope, agentPlist]);
            BOOL up = [self daemonAlive];
            NSLog(@"[app] LaunchAgents bootstrap %@ -> %d %@", scope, up, o2);
            if (up) {
                self.usingLaunchd = YES;
                self.modeLabel.text = @"模式：用户域守护（无需打开 App；重启手机后自动恢复）";
                return;
            }
        }
        // 连 LaunchAgents 都写不进/注册失败：只能前台看门狗，如实说明缺什么
        self.usingLaunchd = NO;
        self.modeLabel.text = binaryOK ? @"模式：前台看门狗（无 root，LaunchAgents 注册失败；装 deb 可系统级自启）"
                                       : @"模式：前台看门狗（无 root，LaunchAgents 注册失败；装 deb 可系统级自启）";
        NSLog(@"[app] autostart degraded: binary=%d plist=%d agent=%d", binaryOK, plistOK, agentOK);
        return;
    }
    NSString *plistPath = jbPath(@"/Library/LaunchDaemons/com.akun.akund.plist");
    runCmd(lc, @[@"bootout", [NSString stringWithFormat:@"system/%@", kLabel]]);
    NSString *out = runCmd(lc, @[@"bootstrap", @"system", plistPath]);
    BOOL ok = [self daemonAlive];
    if (!ok) {
        // TrollStore App 是 mobile 身份：system 域必然被拒，退到自己用户域（重登前一直有效）
        NSString *userScope = [NSString stringWithFormat:@"user/%d", getuid()];
        runCmd(lc, @[@"bootout", [NSString stringWithFormat:@"%@/%@", userScope, kLabel]]);
        out = runCmd(lc, @[@"bootstrap", userScope, plistPath]);
        ok = [self daemonAlive];
        self.usingLaunchd = ok;
        self.modeLabel.text = ok ? @"模式：用户域守护（已注册；重启手机后首开 App 自恢复）"
                                 : @"模式：前台看门狗（launchd 注册被拒）";
    } else {
        self.usingLaunchd = YES;
        self.modeLabel.text = @"模式：系统守护进程（开机自启，无需打开 App）";
    }
    NSLog(@"[app] bootstrap -> %d %@", ok, out);
}

#pragma mark 进程

- (BOOL)spawnFallbackDaemon {
    if (self.childPid > 0) {
        int st = 0;
        if (waitpid(self.childPid, &st, WNOHANG) == 0) return YES;
        self.childPid = 0;
    }
    NSString *path = [self bundleDaemonPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return NO;
    chmod(path.UTF8String, 0755);
    const char *argv[] = { path.UTF8String, "-daemon", NULL };
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, kOutLog.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, kErrLog.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, &fa, NULL, (char **)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc == 0) { self.childPid = pid; return YES; }
    NSLog(@"[app] posix_spawn 失败 rc=%d", rc);
    return NO;
}

- (void)restartService {
    [self status:@"正在重启…" color:COL_WARN];
    NSString *lc = jbPath(@"/usr/bin/launchctl");
    if ([self daemonAlive]) {
        NSString *out = runCmd(lc, @[@"kickstart", @"-k", [NSString stringWithFormat:@"system/%@", kLabel]]);
        NSLog(@"[app] kickstart %@", out);
        sleep(1);
        if ([self daemonAlive]) { [self refresh]; [self toast:@"服务已重启"]; return; }
    }
    if (self.usingLaunchd && ![self daemonAlive]) {
        [self ensureAutoStart];
        sleep(1);
        if ([self daemonAlive]) { [self refresh]; [self toast:@"服务已重启"]; return; }
    }
    if (self.childPid > 0) { kill(self.childPid, SIGTERM); waitpid(self.childPid, NULL, 0); self.childPid = 0; }
    BOOL ok = [self spawnFallbackDaemon];
    [self refresh];
    [self toast:ok ? @"已用看门狗方式重启" : @"重启失败：找不到可执行的 akundd"];
}

#pragma mark 刷新

- (void)status:(NSString *)text color:(UIColor *)c {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusText.text = text;
        self.statusDot.backgroundColor = c;
    });
}

- (void)refresh {
    // 用户自己设的名字（UserAssignedDeviceName）优先：daemon 的 device_info 也用它，
    // 这样 UI 和中控后台看到的是同一个名字，不是默认的 iPhone
    NSString *name = mgString(@"UserAssignedDeviceName") ?: mgString(@"DeviceName")
                   ?: [[UIDevice currentDevice] name] ?: @"iPhone";
    NSString *udid = mgString(@"UniqueDeviceID");
    NSString *ip = localIPv4();
    NSString *model = mgString(@"ProductType") ?: @"未知";
    NSString *modelLine = [NSString stringWithFormat:@"%@ · iOS %@", model, [[UIDevice currentDevice] systemVersion]];
    BOOL alive = [self daemonAlive];
    NSString *pidLine = @"未运行";
    if (alive) {
        // pid 也要三个域一起找：deb 在 system，TrollStore 只能注册进 user/<uid>
        NSString *lc = jbPath(@"/usr/bin/launchctl");
        NSString *out = @"";
        NSArray<NSString *> *scopes = @[ @"system",
                                         [NSString stringWithFormat:@"user/%d", getuid()],
                                         [NSString stringWithFormat:@"gui/%d", getuid()] ];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"pid = ([0-9]+)" options:0 error:nil];
        for (NSString *sc in scopes) {
            NSString *o = runCmd(lc, @[@"print", [NSString stringWithFormat:@"%@/%@", sc, kLabel]]);
            if (o.length) { out = o; if ([re firstMatchInString:o options:0 range:NSMakeRange(0, o.length)]) break; }
        }
        NSTextCheckingResult *m = [re firstMatchInString:out options:0 range:NSMakeRange(0, out.length)];
        if (m) pidLine = [NSString stringWithFormat:@"运行中 pid=%@", [out substringWithRange:[m rangeAtIndex:1]]];
        else if (self.childPid > 0) pidLine = [NSString stringWithFormat:@"运行中 pid=%d", self.childPid];
        else pidLine = @"运行中";
    }

    NSString *err = [NSString stringWithContentsOfFile:kErrLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *arr = [err componentsSeparatedByString:@"\n"];
    NSUInteger from = arr.count > 60 ? arr.count - 60 : 0;
    for (NSUInteger i = from; i < arr.count; i++) if ([arr[i] length]) [lines addObject:arr[i]];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.nameValue.text = name;
        self.udidValue.text = udid.length ? udid : @"读取失败";
        self.ipValue.text = ip;
        self.modelValue.text = modelLine;
        self.pidValue.text = pidLine;
        [self status:alive ? @"服务运行中" : @"服务未运行" color:alive ? COL_OK : COL_BAD];
        self.logView.text = lines.count ? [lines componentsJoinedByString:@"\n"] : @"（暂无日志）";
        if (self.logView.text.length > 1)
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    });
}

- (void)toast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(24, self.window.bounds.size.height - 120,
                                                              self.window.bounds.size.width - 48, 44)];
        l.backgroundColor = [COL_CARD colorWithAlphaComponent:0.96];
        l.textColor = COL_TEXT;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.layer.cornerRadius = 12; l.clipsToBounds = YES;
        l.text = msg;
        l.alpha = 0;
        [self.window addSubview:l];
        [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.3 delay:1.4 options:0 animations:^{ l.alpha = 0; }
                             completion:^(BOOL f2) { [l removeFromSuperview]; }];
        }];
    });
}

- (void)copyUdid {
    NSString *u = self.udidValue.text;
    if (u.length) { [UIPasteboard generalPasteboard].string = u; [self toast:@"UDID 已复制"]; }
}

#pragma mark UI

- (UIView *)cardWithHeight:(CGFloat)h y:(CGFloat)y parent:(UIView *)parent {
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(16, y, parent.bounds.size.width - 32, h)];
    c.backgroundColor = COL_CARD;
    c.layer.cornerRadius = 14;
    c.layer.borderWidth = 0.5;
    c.layer.borderColor = COL_LINE.CGColor;
    [parent addSubview:c];
    return c;
}

- (UILabel *)rowIn:(UIView *)card title:(NSString *)title y:(CGFloat)y {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 84, 22)];
    t.text = title; t.textColor = COL_SUB; t.font = [UIFont systemFontOfSize:13];
    [card addSubview:t];
    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(100, y, card.bounds.size.width - 116, 22)];
    v.textColor = COL_TEXT;
    v.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumScaleFactor = 0.6;
    v.userInteractionEnabled = YES;
    [card addSubview:v];
    return v;
}

- (void)styleField:(UITextField *)f {
    f.backgroundColor = COL_BG;
    f.textColor = COL_TEXT;
    f.borderStyle = UITextBorderStyleNone;
    f.layer.cornerRadius = 10;
    f.layer.borderWidth = 0.5;
    f.layer.borderColor = COL_LINE.CGColor;
    f.font = [UIFont systemFontOfSize:14];
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
    f.leftViewMode = UITextFieldViewModeAlways;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
}

- (void)styleButton:(UIButton *)b title:(NSString *)t bg:(UIColor *)bg fg:(UIColor *)fg {
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 12;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = COL_BG;
    CGFloat w = vc.view.bounds.size.width;
    CGFloat h = vc.view.bounds.size.height;
    CGFloat y = 52;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:vc.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    scroll.showsVerticalScrollIndicator = NO;
    [vc.view addSubview:scroll];
    self.scrollView = scroll;
    UIView *root = scroll;

    // 点空白收键盘
    UITapGestureRecognizer *tapKb = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tapKb.cancelsTouchesInView = NO;
    [root addGestureRecognizer:tapKb];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 30)];
    title.text = @"AKUN Bridge";
    title.textColor = COL_TEXT;
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    [root addSubview:title];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, y + 33, w - 40, 18)];
    sub.text = @"iOS 远控服务 · WebRTC 点对点";
    sub.textColor = COL_SUB;
    sub.font = [UIFont systemFontOfSize:12];
    [root addSubview:sub];
    y += 66;

    // 状态条
    self.statusPill = [[UIView alloc] initWithFrame:CGRectMake(16, y, w - 32, 60)];
    self.statusPill.backgroundColor = COL_CARD;
    self.statusPill.layer.cornerRadius = 14;
    self.statusPill.layer.borderWidth = 0.5;
    self.statusPill.layer.borderColor = COL_LINE.CGColor;
    [root addSubview:self.statusPill];
    self.statusDot = [[UILabel alloc] initWithFrame:CGRectMake(18, 22, 14, 14)];
    self.statusDot.layer.cornerRadius = 7;
    self.statusDot.clipsToBounds = YES;
    self.statusDot.backgroundColor = COL_SUB;
    [self.statusPill addSubview:self.statusDot];
    self.statusText = [[UILabel alloc] initWithFrame:CGRectMake(42, 10, w - 96, 22)];
    self.statusText.text = @"检查中…";
    self.statusText.textColor = COL_TEXT;
    self.statusText.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.statusPill addSubview:self.statusText];
    self.pidValue = [[UILabel alloc] initWithFrame:CGRectMake(42, 30, w - 96, 18)];
    self.pidValue.textColor = COL_SUB;
    self.pidValue.font = [UIFont systemFontOfSize:11];
    [self.statusPill addSubview:self.pidValue];
    y += 72;

    // 设备信息
    UIView *dev = [self cardWithHeight:140 y:y parent:root];
    UILabel *devTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 18)];
    devTitle.text = @"设备信息";
    devTitle.textColor = COL_SUB;
    devTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [dev addSubview:devTitle];
    _nameValue     = [self rowIn:dev title:@"设备名称" y:36];
    _udidValue     = [self rowIn:dev title:@"UDID"    y:60];
    _ipValue       = [self rowIn:dev title:@"本机 IP"  y:84];
    _modelValue    = [self rowIn:dev title:@"型号"    y:108];
    [_udidValue addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyUdid)]];
    y += 152;

    // 连接配置
    UIView *cfg = [self cardWithHeight:154 y:y parent:root];
    UILabel *cfgTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 18)];
    cfgTitle.text = @"连接配置";
    cfgTitle.textColor = COL_SUB;
    cfgTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [cfg addSubview:cfgTitle];
    NSDictionary *prefs = [self loadPrefs];
    self.serverField = [[UITextField alloc] initWithFrame:CGRectMake(16, 38, cfg.bounds.size.width - 32, 44)];
    self.serverField.placeholder = @"信令地址，留空=局域网自动发现";
    self.serverField.text = prefs[@"ServerBase"] ?: @"";
    [self styleField:self.serverField];
    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.delegate = self;
    self.serverField.returnKeyType = UIReturnKeyDone;
    [cfg addSubview:self.serverField];
    self.deviceField = [[UITextField alloc] initWithFrame:CGRectMake(16, 90, cfg.bounds.size.width - 132, 44)];
    self.deviceField.placeholder = @"设备 ID";
    self.deviceField.text = prefs[@"DeviceId"] ?: @"dev001";
    [self styleField:self.deviceField];
    self.deviceField.keyboardType = UIKeyboardTypeASCIICapable;
    self.deviceField.delegate = self;
    self.deviceField.returnKeyType = UIReturnKeyDone;
    self.deviceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [cfg addSubview:self.deviceField];
    self.saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveBtn.frame = CGRectMake(cfg.bounds.size.width - 108, 90, 92, 44);
    [self styleButton:self.saveBtn title:@"保存" bg:COL_LINE fg:COL_TEXT];
    self.saveBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.saveBtn addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [cfg addSubview:self.saveBtn];
    y += 166;

    // 服务
    UIView *svc = [self cardWithHeight:132 y:y parent:root];
    self.restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.restartBtn.frame = CGRectMake(16, 16, svc.bounds.size.width - 32, 50);
    [self styleButton:self.restartBtn title:@"重启服务" bg:COL_ACCENT fg:[UIColor whiteColor]];
    self.restartBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.restartBtn addTarget:self action:@selector(restartService) forControlEvents:UIControlEventTouchUpInside];
    [svc addSubview:self.restartBtn];
    self.modeLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 74, svc.bounds.size.width - 32, 34)];
    self.modeLabel.textColor = COL_SUB;
    self.modeLabel.font = [UIFont systemFontOfSize:12];
    self.modeLabel.numberOfLines = 2;
    self.modeLabel.text = @"模式：检查中…";
    [svc addSubview:self.modeLabel];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 108, svc.bounds.size.width - 32, 18)];
    hint.text = @"重启会断开当前所有观看端连接";
    hint.textColor = COL_SUB;
    hint.font = [UIFont systemFontOfSize:11];
    [svc addSubview:hint];
    y += 144;

    // 日志
    CGFloat logH = MAX(h - y - 20, 100);
    UIView *logCard = [self cardWithHeight:logH y:y parent:root];
    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 18)];
    logTitle.text = @"实时日志";
    logTitle.textColor = COL_SUB;
    logTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [logCard addSubview:logTitle];
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(10, 32, logCard.bounds.size.width - 20, logCard.bounds.size.height - 42)];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.backgroundColor = [UIColor clearColor];
    self.logView.textColor = COL_SUB;
    self.logView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    self.logView.text = @"（加载中）";
    [logCard addSubview:self.logView];

    scroll.contentSize = CGSizeMake(w, y + 20);

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(onKeyboard:)
        name:UIKeyboardWillChangeFrameNotification object:nil];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    [self ensureAutoStart];
    if (!self.usingLaunchd) [self spawnFallbackDaemon];
    [self refresh];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
    return YES;
}

- (void)dismissKeyboard {
    [self.serverField resignFirstResponder];
    [self.deviceField resignFirstResponder];
    [self.scrollView setContentOffset:CGPointZero animated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)onKeyboard:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat overlap = MAX(0, screenH - kb.origin.y);
    UIEdgeInsets in = UIEdgeInsetsMake(0, 0, overlap, 0);
    self.scrollView.contentInset = in;
    self.scrollView.scrollIndicatorInsets = in;
}

- (void)onSave {
    [self.serverField resignFirstResponder];
    [self.deviceField resignFirstResponder];
    [self savePrefs:YES];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([BridgeAppDelegate class]));
    }
}
