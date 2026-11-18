//  AkunInjector — 触摸注入入口
//
//  这里不再自己拼 IOHIDEvent：直接把 AKUN（TrollVNC）的 STHIDEventGenerator 原样搬进
//  src/vendor/ 逐字复用（它是真机验证过能控制 SpringBoard 的那一份）。
//  我们自己手搓的版本试过归一化坐标、掩码、异步发送、senderID 等多种组合，控制始终无效果，
//  所以改成"用它的代码、只换传输层为 WebRTC"。
//
//  注意坐标口：STHIDEventGenerator 收的是**屏幕像素坐标**，内部自己除以
//  _unjailedReferenceBoundsInPixels（1080x1920）再喂 HID，所以网页来的 0~1 要先乘回来。

#import "AkunInjector.h"
#include <spawn.h>
extern char **environ;
#import "AkunCapture.h"

// 全局：最后一次触摸注入的时刻（给抓屏侧算「点击→出帧」用）
double gLastInputMono = 0.0;

// 抓屏侧提供的「跟手升帧」钩子：每次注入输入就通知它，抓屏会在 1.2 秒内抬到 40fps
extern void AkunBridgeNoteInteraction(void);
#import "AkunOrientation.h"

#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdio.h>
#import <unistd.h>
#import <signal.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <sys/stat.h>

// ---- 私有 API 的轻量调用助手（辅助功能用）----
static id akun_msg0(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) { return nil; }
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(obj, s);
}
static __attribute__((unused)) id akun_msg1(id obj, NSString *sel, id a) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) { return nil; }
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return fn(obj, s, a);
}
static BOOL akun_bool1(id obj, NSString *sel, id a) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) { return NO; }
    BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return fn(obj, s, a);
}
// LSApplicationWorkspace：私有框架，daemon 里 dlopen 后按类名取
static id akun_appWorkspace(void) {
    static id ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore", RTLD_LAZY);
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        ws = akun_msg0(c, @"defaultWorkspace");
    });
    return ws;
}

// —— AKUN 对齐用的进程表工具 ——
// AKUN 明确警告：mobile 身份下 SpringBoardServices/FrontBoard 的 XPC（terminateApplication:）
// 会无限等、把 action 线程卡死。所以一律走 sysctl 进程表 + kill()，纯本地调用。
static NSDictionary<NSString *, NSNumber *> *akun_proc_map(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return map;
    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(len);
    if (!kp) return map;
    if (sysctl(mib, 4, kp, &len, NULL, 0) == 0) {
        int n = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < n; i++) {
            pid_t pid = kp[i].kp_proc.p_pid;
            if (pid <= 1) continue;
            const char *comm = kp[i].kp_proc.p_comm;
            if (!comm || !comm[0]) continue;
            NSString *name = [NSString stringWithUTF8String:comm];
            if (name.length && !map[name]) map[name] = @(pid);
        }
    }
    free(kp);
    return map;
}

static int akun_pid_for_exec(NSString *exec) {
    if (!exec.length) return 0;
    NSDictionary *map = akun_proc_map();
    NSNumber *exact = map[exec];
    if (exact) return exact.intValue;
    // p_comm 只有 16 字节，长可执行名会被截断，退化到前缀匹配
    if (exec.length > 16) {
        NSString *prefix = [exec substringToIndex:16];
        for (NSString *k in map) {
            NSNumber *n = map[k];
            if ([k hasPrefix:prefix]) return n.intValue;
        }
    }
    return 0;
}

// bundle → 主可执行名（LSApplicationProxy.bundleExecutable，取不到读 Info.plist）
static NSString *akun_bundle_exec(NSString *bundle) {
    if (!bundle.length) return nil;
    if ([bundle isEqualToString:@"com.apple.SpringBoard"]) return @"SpringBoard";
    id proxy = nil;
    Class pc = NSClassFromString(@"LSApplicationProxy");
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (pc && [pc respondsToSelector:sel]) {
        proxy = ((id (*)(id, SEL, id))objc_msgSend)(pc, sel, bundle);
    }
    NSString *ex = nil;
    @try { ex = [proxy valueForKey:@"bundleExecutable"]; } @catch (__unused NSException *e) {}
    if (!ex.length) {
        NSString *bp = nil;
        @try { bp = [[proxy valueForKey:@"bundleURL"] path]; } @catch (__unused NSException *e) {}
        if (bp.length) {
            NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:
                                [bp stringByAppendingPathComponent:@"Info.plist"]];
            ex = pl[@"CFBundleExecutable"];
        }
    }
    return (ex.length) ? ex : nil;
}

// 真实显示名：<lang>.lproj/InfoPlist.strings 优先（daemon 没有语言偏好，localizedInfoDictionary
// 会退回 Base 名，所以必须先读文件）
static NSString *akun_app_localized_name(NSString *appPath, NSString *fallback) {
    if (!appPath.length) return fallback;
    for (NSString *lproj in @[ @"zh-Hans.lproj", @"zh-Hant.lproj", @"zh-Hans-CN.lproj",
                                @"zh-Hans-HK.lproj", @"zh_CN.lproj" ]) {
        NSString *p = [appPath stringByAppendingPathComponent:
                       [lproj stringByAppendingPathComponent:@"InfoPlist.strings"]];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *v = d[@"CFBundleDisplayName"];
        if (![v isKindOfClass:[NSString class]] || !v.length) v = d[@"CFBundleName"];
        if ([v isKindOfClass:[NSString class]] && v.length) return v;
    }
    NSDictionary *mainInfo = [NSDictionary dictionaryWithContentsOfFile:
                              [appPath stringByAppendingPathComponent:@"Info.plist"]];
    if ([mainInfo isKindOfClass:[NSDictionary class]]) {
        NSString *dn = mainInfo[@"CFBundleDisplayName"];
        if ([dn isKindOfClass:[NSString class]] && dn.length) return dn;
    }
    return fallback;
}

// 扫 App 容器目录补漏：TrollStore / 侧载 / 隐藏安装不会出现在 LS 里
static void akun_scan_app_bundles(NSString *root, NSMutableDictionary *map) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return;
    for (NSString *entry in ([fm contentsOfDirectoryAtPath:root error:nil] ?: @[])) {
        NSString *path = [root stringByAppendingPathComponent:entry];
        BOOL d = NO;
        if (![fm fileExistsAtPath:path isDirectory:&d] || !d) continue;
        NSMutableArray *appPaths = [NSMutableArray array];
        if ([entry hasSuffix:@".app"]) { [appPaths addObject:path]; }
        else {
            for (NSString *sub in ([fm contentsOfDirectoryAtPath:path error:nil] ?: @[])) {
                if ([sub hasSuffix:@".app"]) [appPaths addObject:[path stringByAppendingPathComponent:sub]];
            }
        }
        for (NSString *appPath in appPaths) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [appPath stringByAppendingPathComponent:@"Info.plist"]];
            if (![info isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            NSMutableDictionary *exist = map[bid];
            if (exist) { if (![exist[@"path"] length]) exist[@"path"] = appPath; continue; }
            NSString *nm = info[@"CFBundleDisplayName"];
            if (![nm isKindOfClass:[NSString class]] || !nm.length) nm = info[@"CFBundleName"];
            nm = akun_app_localized_name(appPath, nm);
            if (![nm isKindOfClass:[NSString class]] || !nm.length) nm = bid;
            map[bid] = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                        bid, @"bundle", nm, @"name", appPath, @"path", nil];
        }
    }
}



#import "vendor/STHIDEventGenerator.h"
#import "vendor/Logging.h"
#import "vendor/UIScreen+Private.h"

// STHIDEventGenerator 依赖的外部符号
BOOL tvncLoggingEnabled = NO;
BOOL tvncVerboseLoggingEnabled = NO;
int gOrientationFixQuad = 0;

// 这几个入口在 .h 里没有，但 AKUN 的 vnc 服务就是直接这么调的（见 trollvncserver.mm ptrAddEvent）
// 键盘通道：AKUN 的 input_text 就是「写剪贴板 + Cmd+V」，走的正是这个方法
@interface STHIDEventGenerator (AkunPrivateKeyboard)
- (void)_sendIOHIDKeyboardEvent:(uint32_t)page usage:(uint32_t)usage isKeyDown:(boolean_t)isKeyDown;
@end

@interface STHIDEventGenerator (AkunPrivateTouch)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
- (CGSize)akun_physicalScreenSize;
@end

@implementation AkunInjector {
    double _startX;   // 0~1
    double _startY;
    double _lastX;
    double _lastY;
    BOOL _dragging;
    double _downTime;
}

/// 跑一个外部命令并收集输出（root 下的 dpkg / unzip 用）。返回退出码，输出带回。
/// 只在 handleAux 里被安装/卸载类动作调用，调用期间会阻塞控制通道，和 AKUN 的语义一致。

// 低层文件探测/读取：rootless 注入环境下 NSFileManager 的 fileExistsAtPath 对
// /var、/tmp 下的新文件会莫名返回 false（dataWithContentsOfFile 也拿不到），
// 而同一个进程自己就在往这些目录写日志。改用 POSIX stat/fopen，绕开这一层。

// 从 root 侧 dpkgd（回环 TCP）取 dpkg status 原文：RootHide 下文件共享走不通，
// 这是唯一稳定通道。失败返回 nil。
// 给 root dpkgd 发任意指令（DPKG_I / DPKG_R / TIPAQ），返回原始回包。
static NSData *akun_root_cmd(NSString *req, int *rcOut, NSString **outStr) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval tv = { 30, 0 };            // dpkg 装包可能久，给 30 秒
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(19949);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return nil; }
    NSData *rd = [req dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, rd.bytes, rd.length);
    NSMutableData *acc = [NSMutableData data];
    char b[8192];
    ssize_t n = 0;
    while ((n = recv(fd, b, sizeof(b), 0)) > 0) {
        [acc appendBytes:b length:n];
        if (acc.length > 524288) break;
    }
    close(fd);
    NSString *txt = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
    if (!txt.length) txt = [[NSString alloc] initWithData:acc encoding:NSISOLatin1StringEncoding];
    if (outStr) *outStr = txt ?: @"";
    if (rcOut) {
        int rc = -1;
        if ([txt hasPrefix:@"OK "]) { rc = [[txt substringFromIndex:3] intValue]; }
        *rcOut = rc;
    }
    return acc;
}

// 发「首行 + 二进制正文」两段给 dpkgd：RootHide 下注入进程和 dpkg 的文件视图不共享，
// 上传的包必须由 root 侧 dpkgd 自己落盘，否则 dpkg 永远 no such file。
static NSData *akun_root_cmd_body(NSString *head, NSData *body, int *rcOut, NSString **outStr) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval tv = { 20, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(19949);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return nil; }

    NSMutableData *all = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    if (body.length) [all appendData:body];
    const char *p = (const char *)all.bytes;
    NSUInteger left = all.length;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w <= 0) break;
        p += w; left -= (NSUInteger)w;
    }
    NSMutableData *acc = [NSMutableData data];
    char b[8192];
    ssize_t n = 0;
    while ((n = recv(fd, b, sizeof(b), 0)) > 0) {
        [acc appendBytes:b length:n];
        if (acc.length > 524288) break;
    }
    close(fd);
    NSString *txt = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
    if (!txt.length) txt = [[NSString alloc] initWithData:acc encoding:NSISOLatin1StringEncoding];
    if (outStr) *outStr = txt ?: @"";
    if (rcOut) {
        int rc = -1;
        if ([txt hasPrefix:@"OK "]) { rc = [[txt substringFromIndex:3] intValue]; }
        *rcOut = rc;
    }
    return acc;
}

static NSData *akun_fetch_dpkg_tcp(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return nil;
    struct timeval tv;
    tv.tv_sec = 4;
    tv.tv_usec = 0;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((uint16_t)port);
    if (connect(s, (struct sockaddr *)&a, sizeof(a)) != 0) { close(s); return nil; }
    const char *req = "LIST\n";
    write(s, req, 5);
    NSMutableData *d = [NSMutableData data];
    char b[8192];
    ssize_t n = 0;
    while ((n = recv(s, b, sizeof(b), 0)) > 0) { [d appendBytes:b length:(NSUInteger)n]; }
    close(s);
    return d.length ? d : nil;
}

static int akun_stat_mode(NSString *p) {
    if (!p.length) return -1;
    struct stat st;
    if (stat(p.UTF8String, &st) != 0) return -1;
    return (int)st.st_mode;
}

// ---------- device_info 用的探针（逐条对齐 AKUN TVNCDeviceInfo） ----------

// MobileGestalt：用户改的设备名、ProductType、真 UDID、序列号都只能从这里拿。
// [[UIDevice currentDevice] name] 在 daemon 里永远是出厂名 "iPhone"。
static NSString *akun_mg_string(NSString *key) {
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

// roothide 的越狱根：/var/containers/Bundle/Application/.jbroot-XXXX
static NSString *akun_jbroot_path(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *parent = @"/var/containers/Bundle/Application";
        NSArray *es = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:nil];
        for (NSString *e in es) {
            if ([e hasPrefix:@".jbroot-"]) {
                cached = [parent stringByAppendingPathComponent:e];
                break;
            }
        }
    });
    return cached;
}

// 真写一个探针再删：查权限位不准（沙盒/ACL/sticky 位都盖不到）
static BOOL akun_probe_writable(NSString *p) {
    if (!p.length) return NO;
    int fd = open(p.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return NO;
    close(fd);
    unlink(p.UTF8String);
    return YES;
}

static BOOL akun_binary_has_setuid(NSString *p) {
    if (!p.length) return NO;
    struct stat st;
    if (stat(p.UTF8String, &st) != 0) return NO;
    return (st.st_mode & S_ISUID) != 0;
}

// 我方 root 通道是 dpkgd（127.0.0.1:19949），对应 AKUN 的 trollvnc-rootd socket 探测
static BOOL akun_dpkgd_up(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NO;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(19949);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0);
    close(s);
    return ok;
}

static NSData *akun_fread_all(NSString *p) {
    if (!p.length) return nil;
    FILE *f = fopen(p.UTF8String, "rb");
    if (!f) return nil;
    NSMutableData *d = [NSMutableData data];
    char buf[8192];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) { [d appendBytes:buf length:n]; }
    fclose(f);
    return d.length ? d : nil;
}

__attribute__((unused)) static int akun_spawn_capture(NSArray<NSString *> *argv, NSString **outText) {
    if (argv.count == 0) { return -1; }
    int fds[2];
    if (pipe(fds) != 0) { return -1; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);

    char **cargv = (char **)calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) {
        cargv[i] = strdup([argv[i] fileSystemRepresentation]);
    }
    const char *cpath = [argv[0] fileSystemRepresentation];
    pid_t pid = 0;
    int rc = posix_spawn(&pid, cpath, &fa, NULL, cargv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    for (NSUInteger i = 0; i < argv.count; i++) { free(cargv[i]); }
    free(cargv);
    if (rc != 0) {
        close(fds[0]);
        NSLog(@"[aux] 启动 %@ 失败 rc=%d", argv[0], rc);
        return -1;
    }
    // 必须一直读到 EOF，不能读满就 close：dpkg-query 输出 ~120KB，提前关读端会让子进程
    // 写 stdout 拿到 EPIPE/SIGPIPE 被杀，waitpid 得到非正常退出 → rc=-1（list_packages 挂就是这原因）。
    // 这里只对「保存」做截断，读动作仍然读尽。
    static const NSUInteger kCap = 1048576;
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    ssize_t n = 0;
    while ((n = read(fds[0], tmp, sizeof(tmp))) > 0) {
        if (buf.length < kCap) {
            NSUInteger room = kCap - buf.length;
            if ((NSUInteger)n > room) { n = (ssize_t)room; }
            if (n > 0) { [buf appendBytes:tmp length:(NSUInteger)n]; }
        }
    }
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (outText) { *outText = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @""; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

- (instancetype)init {
    if ((self = [super init])) {
        tvncLoggingEnabled = YES;   // 它内部的 TVLog 走 NSLog，方便真机排错
        NSLog(@"[inject] 使用 AKUN STHIDEventGenerator 注入");
    }
    return self;
}

/// 屏幕像素尺寸：**必须**用 generator 内部同一份基准，
/// 它据此除以归一化（我们这边若用别的尺寸，落点就会整体偏移）。
- (CGSize)pixelSize {
    CGSize s = CGSizeZero;
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    s = [gen akun_physicalScreenSize];
    if (s.width < 1 || s.height < 1) {
        CGRect r = CGRectZero;
        @try {
            r = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels];
        } @catch (NSException *e) {
        }
        if (r.size.width < 1 || r.size.height < 1) {
            r = CGRectMake(0, 0, 1080, 1920);
        }
        s = r.size;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[inject] generator 归一化基准 = %.0fx%.0f", s.width, s.height);
    });
    return s;
}

static double clamp01(double v) {
    if (v < 0) { return 0; }
    if (v > 1) { return 1; }
    return v;
}

/// 归一化坐标 → 竖屏物理像素。
/// quad != 0 时，客户端看到的是「转过的画面」，这里按 AKUN 的 vncPointToDevicePoint
/// 反向旋转，保证点哪就是哪（不修这段，横屏下点按会整体偏、甚至点不中）。
- (CGPoint)pointFromNormX:(double)x y:(double)y {
    CGSize s = [self pixelSize];
    double W = s.width, H = s.height;
    double nx = clamp01(x), ny = clamp01(y);
    int q = [AkunOrientation quad];

    // 旋转后的舞台尺寸
    double rotW = (q % 2 == 0) ? W : H;
    double rotH = (q % 2 == 0) ? H : W;
    double stX = nx * rotW;
    double stY = ny * rotH;

    double dx = 0, dy = 0;
    switch (q) {
    case 1:  // 90°CW：stageX = srcH-1-srcY, stageY = srcX  =>  srcX = stageY, srcY = srcH-1-stageX
        dx = stY;
        dy = (H - 1) - stX;
        break;
    case 2:  // 180°
        dx = (W - 1) - stX;
        dy = (H - 1) - stY;
        break;
    case 3:  // 270°CW
        dx = (W - 1) - stY;
        dy = stX;
        break;
    case 0:
    default:
        dx = stX;
        dy = stY;
        break;
    }
    if (dx < 0) { dx = 0; }
    if (dy < 0) { dy = 0; }
    if (dx > W - 1) { dx = W - 1; }
    if (dy > H - 1) { dy = H - 1; }
    return CGPointMake(dx, dy);
}

- (void)handleCommand:(NSDictionary *)cmd {
    NSString *t = cmd[@"t"];
    if (![t isKindOfClass:[NSString class]]) { return; }

    double x = clamp01([cmd[@"x"] doubleValue]);
    double y = clamp01([cmd[@"y"] doubleValue]);

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];

    if ([t isEqualToString:@"tap"]) {
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] tap 像素 (%f,%f)", p.x, p.y);
        // 不用 gen 的 tap: —— 它内部 _sendTaps 断言 delay>0 而自身传 0，带断言编译会 abort。
        // 走 touchDown/touchUp 两段，等价 AKUN 的 tap 行为。
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();   // 进交互窗口：抓屏强制出帧 + 抬码率
        [gen touchDownAtPoints:&p touchCount:1];
        // 对齐 AKUN：STHIDEventGenerator 里 fingerLiftDelay = 0.05，即「按下→50ms→抬起」
        NSUInteger ms = cmd[@"ms"] ? [cmd[@"ms"] unsignedIntValue] : 50;
        if (ms < 30) { ms = 30; }
        if (ms > 800) { ms = 800; }
        usleep((useconds_t)(ms * 1000));
        [gen liftUpAtPoints:&p touchCount:1];
        NSLog(@"[inject] tap 完成（按住 %lu ms）", (unsigned long)ms);
    } else if ([t isEqualToString:@"d"]) {
        // 与 AKUN ptrAddEvent 一致：按下发 touchDown，移动发 _updateTouchPoints，抬起发 liftUp
        _dragging = YES;
        _startX = x; _startY = y; _lastX = x; _lastY = y;
        _downTime = CACurrentMediaTime();
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] down (%f,%f)", p.x, p.y);
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();
        [gen touchDownAtPoints:&p touchCount:1];
    } else if ([t isEqualToString:@"m"]) {
        if (_dragging) {
            _lastX = x; _lastY = y;
            CGPoint p = [self pointFromNormX:x y:y];
            [gen _updateTouchPoints:&p count:1];
        }
    } else if ([t isEqualToString:@"u"]) {
        if (_dragging) {
            _dragging = NO;
            CGPoint b = [self pointFromNormX:(x > 0 ? x : _lastX) y:(y > 0 ? y : _lastY)];
            // 最短按住 60ms：网页鼠标点按常常只有 20~40ms，SpringBoard 会当成无效触摸丢掉；
            // 但按太久也会直接加延迟（触摸是松手才生效），60ms 是「不被丢」和「不拖」的折中
            double held = CACurrentMediaTime() - _downTime;
            if (held < 0.05) { usleep((useconds_t)((0.05 - held) * 1e6)); }
            NSLog(@"[inject] up (%f,%f) 按住 %.0fms", b.x, b.y, held * 1000);
            [gen liftUpAtPoints:&b touchCount:1];
        }
    } else if ([t isEqualToString:@"dtap"]) {
        // 双击：走 AKUN 的 doubleTap（内部间隔 0.15s），比网页连发两次单击更可靠
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] dtap (%f,%f)", p.x, p.y);
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();
        [gen doubleTap:p];
    } else if ([t isEqualToString:@"swipe"]) {
        CGPoint a = [self pointFromNormX:x y:y];
        CGPoint b = [self pointFromNormX:[cmd[@"x2"] doubleValue] y:[cmd[@"y2"] doubleValue]];
        AkunBridgeNoteInteraction();
        [gen dragLinearWithStartPoint:a endPoint:b duration:0.25];
    } else if ([t isEqualToString:@"k"]) {
        NSString *code = cmd[@"code"];
        if ([code isEqualToString:@"home"]) {
            // 以前这里既不打点也不记时刻，导致「按 home → 画面」这段无法被 [lat] 量到
            gLastInputMono = CACurrentMediaTime();
            AkunBridgeNoteInteraction();
            NSLog(@"[inject] home");
            [gen menuPress];
        }
    } else if ([t isEqualToString:@"hk"]) {
        unsigned int usage = [cmd[@"usage"] unsignedIntValue];
        unsigned int mod = [cmd[@"mod"] unsignedIntValue];
        unsigned int usagePage = [cmd[@"page"] unsignedIntValue];
        if (usagePage == 0) { usagePage = 0x07; }   // 默认键盘页
        if (mod) {
            // 通用组合键：修饰键按住 → 主键按下/抬起 → 修饰键抬起（Cmd+L / Cmd+A / Cmd+V 等）
            gLastInputMono = CACurrentMediaTime();
            AkunBridgeNoteInteraction();
            [gen _sendIOHIDKeyboardEvent:usagePage usage:mod isKeyDown:true];
            usleep(20000);
            [gen _sendIOHIDKeyboardEvent:usagePage usage:usage isKeyDown:true];
            usleep(20000);
            [gen _sendIOHIDKeyboardEvent:usagePage usage:usage isKeyDown:false];
            usleep(20000);
            [gen _sendIOHIDKeyboardEvent:usagePage usage:mod isKeyDown:false];
            NSLog(@"[inject] hk mod=0x%X usage=0x%X", mod, usage);
        }
        else if (usage == 0xE9) { [gen volumeIncrementPress]; }
        else if (usage == 0xEA) { [gen volumeDecrementPress]; }
        else if (usage == 0x223) { [gen menuPress]; }
        else if (usage) {
            // 单键（不带修饰）
            gLastInputMono = CACurrentMediaTime();
            AkunBridgeNoteInteraction();
            [gen _sendIOHIDKeyboardEvent:usagePage usage:usage isKeyDown:true];
            usleep(30000);
            [gen _sendIOHIDKeyboardEvent:usagePage usage:usage isKeyDown:false];
            NSLog(@"[inject] hk key usage=0x%X", usage);
        }
    }
}


// 亮度：AKUN 用 BrightnessSystemClient 的 setProperty:forKey:@"DisplayBrightness"。
// UIScreen.brightness 在 daemon 进程里只是本地属性，改不动真实背光。
static BOOL akun_set_brightness(CGFloat v) {
    Class cls = NSClassFromString(@"BrightnessSystemClient");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/BrightnessControl.framework/BrightnessControl", RTLD_LAZY);
        cls = NSClassFromString(@"BrightnessSystemClient");
    }
    if (cls) {
        id client = [[cls alloc] init];
        SEL sel = NSSelectorFromString(@"setProperty:forKey:");
        if ([client respondsToSelector:sel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(client, sel, @(v), @"DisplayBrightness");
            return YES;
        }
    }
    [UIScreen mainScreen].brightness = v;
    return NO;
}

static CGFloat akun_get_brightness(void) {
    Class cls = NSClassFromString(@"BrightnessSystemClient");
    if (cls) {
        id client = [[cls alloc] init];
        SEL sel = NSSelectorFromString(@"copyPropertyForKey:");
        if ([client respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL, id))objc_msgSend)(client, sel, @"DisplayBrightness");
            if ([val respondsToSelector:@selector(doubleValue)]) return (CGFloat)[val doubleValue];
        }
    }
    return [UIScreen mainScreen].brightness;
}

// 读当前系统音量（Audio/Video 类别）；读不到回 -1，便于调用方区分「0」和「失败」
static CGFloat akun_get_volume(void) {
    Class avsc = NSClassFromString(@"AVSystemController");
    id shared = akun_msg0(avsc, @"sharedAVSystemController");
    SEL s = NSSelectorFromString(@"getVolume:forCategory:");
    if (shared && [shared respondsToSelector:s]) {
        float v = -1.0f;
        BOOL (*fn)(id, SEL, float *, id) = (BOOL (*)(id, SEL, float *, id))objc_msgSend;
        if (fn(shared, s, &v, @"Audio/Video")) return (CGFloat)v;
    }
    return -1.0;
}

// 与 AKUN TVNCUploadPathAllowed 逐字一致：绝对路径、≤512、无 ".."、
// 必须 /tmp/ 或 /var/mobile/ 前缀、后缀 .deb/.tipa/.ipa（不区分大小写）
static BOOL akun_pkg_path_allowed(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0 || path.length > 512) return NO;
    if (![path isAbsolutePath] || [path rangeOfString:@".."].location != NSNotFound) return NO;
    if (!([path hasPrefix:@"/tmp/"] || [path hasPrefix:@"/var/mobile/"])) return NO;
    NSString *lower = path.lowercaseString;
    return [lower hasSuffix:@".deb"] || [lower hasSuffix:@".tipa"] || [lower hasSuffix:@".ipa"];
}

// 与 AKUN TVNCDeletePkgFile 等价：自己 unlink，失败再交 rootd（DELE）删；
// mobile 身份删不掉 root 属主文件，这是必需的后备
static BOOL akun_delete_pkg_file(NSString *path) {
    if (path.length == 0) return NO;
    if (unlink(path.UTF8String) == 0) return YES;
    int rc = -1;
    NSString *out = nil;
    akun_root_cmd([NSString stringWithFormat:@"DELE %@", path], &rc, &out);
    return (rc == 0);
}


#pragma mark - AKUN 对齐补充：辅助触控 / 守护重启 / Darwin 通知

static void akunPostDarwin(const char *name) {
    if (!name) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)[NSString stringWithUTF8String:name],
                                         NULL, NULL, true);
}

// AXSettings 是系统设置里开关辅助触控真正走的那条路径；只在内存层面生效，必须再广播通知
static BOOL akunApplyViaAXSettings(BOOL enable) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"AXSettings")) {
            dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
        }
    });
    Class cls = NSClassFromString(@"AXSettings");
    if (!cls) return NO;
    id shared = akun_msg0((id)cls, @"sharedInstance");
    if (!shared) return NO;
    for (NSString *name in @[@"setAssistiveTouchEnabled:", @"_setAssistiveTouchEnabled:", @"setAssistiveTouch:"]) {
        SEL sel = NSSelectorFromString(name);
        if ([shared respondsToSelector:sel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(shared, sel, enable);
            NSLog(@"[aux] assistive touch via AXSettings %@", name);
            return YES;
        }
    }
    for (NSString *key in @[@"assistiveTouchEnabled", @"_assistiveTouchEnabled"]) {
        @try {
            [shared setValue:@(enable) forKey:key];
            NSLog(@"[aux] assistive touch via AXSettings KVC %@", key);
            return YES;
        } @catch (__unused NSException *e) { }
    }
    return NO;
}

static Class akunAssistiveDetailClass(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"PSAssistiveTouchSettingsDetail")) {
            dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
            dlopen("/System/Library/PrivateFrameworks/PreferenceSettings.framework/PreferenceSettings", RTLD_LAZY);
        }
    });
    return NSClassFromString(@"PSAssistiveTouchSettingsDetail");
}

// 照搬 AKUN TVNCApplyAssistiveTouch 的五步：
//   1) 偏好落盘  2) AXSettings（系统设置里那个开关走的就是它）  3) PSAssistiveTouchSettingsDetail
//   4) 三条 Darwin 广播  5) rootd 摘掉/挂回 com.apple.assistivetouchd 的 launchd job
// 第 5 步是关键：SpringBoard 的开关在内存里，只改偏好+发通知改不动它；job 摘掉后连触摸都拉不起来。
// 设备上这个 job 的 plist 在 /rootfs/System/Library/LaunchDaemons/（roothide 视图），已实测存在。
static NSDictionary *akunApplyAssistiveTouch(BOOL enable) {
    CFPreferencesSetAppValue(CFSTR("AssistiveTouchEnabled"),
                             (__bridge CFPropertyListRef)(@(enable)),
                             CFSTR("com.apple.Accessibility"));
    BOOL prefOk = CFPreferencesAppSynchronize(CFSTR("com.apple.Accessibility"));

    BOOL axOk = akunApplyViaAXSettings(enable);

    Class detail = akunAssistiveDetailClass();
    BOOL prefsOk = NO;
    if (detail && [detail respondsToSelector:@selector(setEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)((id)detail, @selector(setEnabled:), enable);
        prefsOk = YES;
    }

    akunPostDarwin("com.apple.accessibility.assistiveTouch.changed");
    akunPostDarwin("com.apple.accessibility.axsettings.changed");
    akunPostDarwin("AXAssistiveTouchEnabledChanged");

    // 5) root 侧 job：开 = bootstrap(user/foreground) + kickstart(-kp user/501)，
    //    关 = bootout(system)，与 AKUN rootd 的 assistive_job_on/off 完全一致
    int jobRc = -1;
    NSString *jobOut = @"";
    akun_root_cmd(enable ? @"ASSIST_ON" : @"ASSIST_OFF", &jobRc, &jobOut);

    BOOL now = enable;
    if (detail && [detail respondsToSelector:@selector(isEnabled)]) {
        now = ((BOOL (*)(id, SEL))objc_msgSend)((id)detail, @selector(isEnabled));
    }
    NSLog(@"[aux] assistive touch enable=%d pref=%d ax=%d prefs=%d job=%d now=%d out=%@",
          enable, prefOk, axOk, prefsOk, jobRc, now, jobOut);
    NSString *jobState = (jobRc == 0)
        ? (enable ? @"bootstrap+kickstart" : @"bootout")
        : [NSString stringWithFormat:@"failed(%d)%@", jobRc, jobOut.length ? jobOut : @""];
    return @{ @"success" : @YES,
              @"enabled" : @(now),
              @"action" : (enable ? @"assistive_touch_on" : @"assistive_touch_off"),
              @"via" : @{ @"pref" : @(prefOk), @"axsettings" : @(axOk),
                          @"preferences" : @(prefsOk), @"job" : jobState },
              @"effective" : @{ @"pref_written" : @(prefOk),
                               @"axsettings_applied" : @(axOk),
                               @"settings_detail" : @(prefsOk),
                               @"runtime_enabled" : @(now),
                               @"job_ok" : @(jobRc == 0) },
              // 如实汇报：只有 job 真的起来了才说“已拉起”。
              // 本机（iPhone10,2 / iOS 16.7.16 / roothide）实测 launchd 里没有 com.apple.assistivetouchd，
              // 球由 LaunchAngel com.apple.AccessibilityUIServer 画，kickstart 不支持 LaunchAngel，
              // 所以这里会回 job_ok=false，不会拿“接口通了”冒充“球出来了”。
              @"note" : (enable
                         ? (jobRc == 0
                            ? @"偏好已写 true，assistivetouchd 已 bootstrap+kickstart"
                            : [NSString stringWithFormat:@"偏好已写 true（设置里辅助触控显示为开），但本机无 assistivetouchd 服务可拉起：%@", jobOut])
                         : (jobRc == 0
                            ? @"偏好已写 false，assistivetouchd 已 bootout 并杀掉"
                            : [NSString stringWithFormat:@"偏好已写 false，但本机无 assistivetouchd 服务：%@", jobOut])) };
}

static NSDictionary *akunGetAssistiveTouch(void) {
    Class detail = akunAssistiveDetailClass();
    BOOL hasDetail = (detail && [detail respondsToSelector:@selector(isEnabled)]);
    BOOL now = NO;
    if (hasDetail) {
        now = ((BOOL (*)(id, SEL))objc_msgSend)((id)detail, @selector(isEnabled));
    } else {
        id v = (__bridge id)CFPreferencesCopyAppValue(CFSTR("AssistiveTouchEnabled"),
                                                      CFSTR("com.apple.Accessibility"));
        now = v ? [v boolValue] : NO;
    }
    return @{ @"success" : @YES, @"enabled" : @(now), @"source" : (hasDetail ? @"runtime" : @"pref") };
}

// 照搬 AKUN TVNCRestartDaemon：先回包，1.5 秒后 SIGTERM 自己，launchd(KeepAlive) 用磁盘新二进制拉起
static NSDictionary *akunRestartDaemon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSLog(@"[aux] restart_daemon: SIGTERM self pid=%d", (int)getpid());
        kill(getpid(), SIGTERM);
        sleep(3);
        kill(getpid(), SIGKILL);
    });
    return @{ @"success" : @YES, @"via" : @"SIGTERM", @"delay_seconds" : @1.5,
              @"note" : @"launchd 会用磁盘上的二进制重新拉起，期间 WS 会短暂断开" };
}

// 照搬 AKUN TVNCPostNotifications：诊断用，直接往 Darwin 通知中心发指定名字
static NSDictionary *akunPostNotifications(id rawNames) {
    NSArray *names = nil;
    if ([rawNames isKindOfClass:[NSArray class]]) names = rawNames;
    else if ([rawNames isKindOfClass:[NSString class]]) names = @[(NSString *)rawNames];
    if (!names.count) return @{ @"success" : @NO, @"error" : @"missing 'names' (string or array)" };
    NSMutableArray *posted = [NSMutableArray array];
    for (id item in names) {
        if (![item isKindOfClass:[NSString class]]) continue;
        akunPostDarwin([(NSString *)item UTF8String]);
        [posted addObject:item];
    }
    return @{ @"success" : @YES, @"posted" : posted };
}

// ---- tipa：逐字照抄 AKUN TVNCTipaServeClient / TVNCTipaServerEnsureStarted ----
// TrollStore 的 apple-magnifier://install?url= 只认它能自己下载到的地址：
// file:// 被沙盒拦（-1100），http:// 实测可用。所以 127.0.0.1 起一个只服务当前这一个文件的
// 极简 HTTP，把地址交给 TrollStore，由它回环下载 → 签名 → 弹安装确认框。
// 关键点：签名是 TrollStore 做的，我们绝不能自己 unzip 到 /Applications（未签名必闪退）。
static int gTipaFD = -1;
static uint16_t gTipaPort = 0;
static dispatch_queue_t gTipaQueue = nil;
static dispatch_source_t gTipaSource = nil;
static NSString *gTipaPath = nil;

static void akun_tipa_serve(int cfd, NSString *path) {
    char head[4096];
    ssize_t n = recv(cfd, head, sizeof(head) - 1, 0);
    if (n <= 0) { close(cfd); return; }
    head[n] = '\0';
    // 流式下发：只开 fd 按 64KB 读，不把整包读进内存（大包会顶到几百 MB）
    int fd = path ? open(path.UTF8String, O_RDONLY) : -1;
    long long fileSize = -1;
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) fileSize = (long long)st.st_size;
    }
    BOOL ok = (fd >= 0 && fileSize >= 0);
    char hdr[384];
    snprintf(hdr, sizeof(hdr),
             "HTTP/1.1 %s\r\nContent-Type: application/octet-stream\r\n"
             "Content-Length: %lld\r\nConnection: close\r\n\r\n",
             ok ? "200 OK" : "404 Not Found", ok ? fileSize : 0LL);
    size_t hl = strlen(hdr), sent = 0;
    while (sent < hl) {
        ssize_t w = send(cfd, hdr + sent, hl - sent, 0);
        if (w <= 0) { if (errno == EINTR) continue; goto done; }
        sent += (size_t)w;
    }
    if (ok && fileSize > 0) {
        const size_t B = 65536;
        uint8_t *buf = (uint8_t *)malloc(B);
        if (buf) {
            ssize_t r;
            while ((r = read(fd, buf, B)) > 0) {
                size_t off = 0;
                while (off < (size_t)r) {
                    ssize_t w = send(cfd, buf + off, (size_t)r - off, 0);
                    if (w <= 0) { if (errno == EINTR) continue; free(buf); goto done; }
                    off += (size_t)w;
                }
            }
            free(buf);
        }
    }
done:
    if (fd >= 0) close(fd);
    close(cfd);
}

static BOOL akun_tipa_server_ensure(void) {
    if (gTipaFD >= 0) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = 0;                              // 内核分配，避免撞端口
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 8) < 0) {
        close(fd);
        return NO;
    }
    struct sockaddr_in bound;
    socklen_t bl = sizeof(bound);
    if (getsockname(fd, (struct sockaddr *)&bound, &bl) < 0) { close(fd); return NO; }
    gTipaPort = ntohs(bound.sin_port);
    gTipaFD = fd;
    gTipaQueue = dispatch_queue_create("com.akun.bridge.tipa-http", DISPATCH_QUEUE_SERIAL);
    gTipaSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, gTipaQueue);
    dispatch_source_set_event_handler(gTipaSource, ^{
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) return;
        NSString *p = gTipaPath;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            akun_tipa_serve(cfd, p);
        });
    });
    dispatch_resume(gTipaSource);
    NSLog(@"[aux] tipa http server on 127.0.0.1:%u", (unsigned)gTipaPort);
    return YES;
}

#pragma mark - 辅助功能（对标 AKUN 19940 指令集，传输仍走我们自己的 WS）

- (NSDictionary *)handleAux:(NSDictionary *)cmd {
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    NSString *a = cmd[@"a"] ?: cmd[@"action"];   // 兼容 AKUN 19940 风格 {"action":"xxx"}
    if (!a.length) { return @{ @"success" : @NO, @"error" : @"missing action" }; }

    if ([a isEqualToString:@"device_info"]) {
        // 1:1 对齐 AKUN TVNCDeviceInfo：字段名、取值顺序、来源标记都逐条照抄
        struct utsname si;
        uname(&si);
        NSString *machine = [NSString stringWithUTF8String:si.machine] ?: @"unknown";
        NSString *kern = [NSString stringWithUTF8String:si.release] ?: @"unknown";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"machine"] = machine ?: @"unknown";
        info[@"kernel"] = kern ?: @"unknown";
        info[@"process"] = @"akund";
        info[@"uid"] = @(getuid());

        NSString *jbroot = akun_jbroot_path();
        info[@"jailbreak_root"] = (jbroot.length || [fm fileExistsAtPath:@"/var/jb"]) ? @YES : @NO;
        info[@"jbroot"] = jbroot.length ? jbroot : @"";
        BOOL jbWritable = jbroot.length ? [fm isWritableFileAtPath:jbroot] : NO;
        info[@"jbroot_writable"] = @(jbWritable);

        NSString *dpkgBin = jbroot.length ? [jbroot stringByAppendingPathComponent:@"usr/bin/dpkg"]
                                         : @"/var/jb/usr/bin/dpkg";
        info[@"dpkg_present"] = @([fm isExecutableFileAtPath:dpkgBin]);
        NSString *dpkgDebBin = jbroot.length ? [jbroot stringByAppendingPathComponent:@"usr/bin/dpkg-deb"]
                                            : @"/var/jb/usr/bin/dpkg-deb";
        info[@"dpkg_deb_present"] = @([fm isExecutableFileAtPath:dpkgDebBin]);

        BOOL rootdUp = akun_dpkgd_up();
        NSString *helperBin = jbroot.length ? [jbroot stringByAppendingPathComponent:@"usr/bin/akund"]
                                           : @"/usr/bin/akund";
        BOOL helperSetuid = akun_binary_has_setuid(helperBin);
        info[@"rootd_socket"] = rootdUp ? @"up" : @"unreachable";
        info[@"helper_setuid"] = @(helperSetuid);
        NSString *form = (rootdUp || getuid() == 0) ? @"deb" : (jbWritable ? @"roothide" : @"tipa");
        info[@"form"] = form;
        info[@"can_install_deb"] = @(rootdUp || getuid() == 0 || helperSetuid || jbWritable);

        info[@"can_write_tmp"] = @(akun_probe_writable(@"/tmp/.akun-write-probe"));
        info[@"can_write_var_mobile"] = @(akun_probe_writable(@"/var/mobile/.akun-write-probe"));
        info[@"tweak_version"] = @"1.0.0";

        NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *ver = [sv[@"ProductVersion"] isKindOfClass:[NSString class]] ? sv[@"ProductVersion"] : nil;
        NSString *bld = [sv[@"ProductBuildVersion"] isKindOfClass:[NSString class]] ? sv[@"ProductBuildVersion"] : nil;
        if (!ver.length) {
            ver = [[UIDevice currentDevice] systemVersion];
            bld = akun_mg_string(@"BuildVersion");
        }
        if (ver.length) info[@"system_version"] = ver;
        if (bld.length) info[@"build"] = bld;

        NSString *deviceName = akun_mg_string(@"UserAssignedDeviceName");
        NSString *deviceNameSource = @"mobilegestalt";
        if (!deviceName.length) {
            deviceName = akun_mg_string(@"DeviceName");
            deviceNameSource = @"mobilegestalt_default";
        }
        if (!deviceName.length) {
            deviceName = [[UIDevice currentDevice] name];
            deviceNameSource = @"uidevice";
        }
        if (deviceName.length) {
            info[@"device_name"] = deviceName;
            info[@"device_name_source"] = deviceNameSource;
        }

        NSString *productType = akun_mg_string(@"ProductType");
        if (productType.length) info[@"product_type"] = productType;

        NSString *udid = akun_mg_string(@"UniqueDeviceID");
        if (udid.length) {
            info[@"udid"] = udid;
            info[@"udid_source"] = @"mobilegestalt";
        } else {
            NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
            if (idfv.length) {
                info[@"idfv"] = idfv;
                info[@"udid_source"] = @"idfv";
            } else {
                info[@"udid_source"] = @"none";
            }
        }

        NSString *serial = akun_mg_string(@"SerialNumber");
        if (serial.length) info[@"serial"] = serial;

        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        NSString *bundle = env[@"__CFBundleIdentifier"];
        if (bundle) info[@"bundle"] = bundle;

        return info;
    }
    if ([a isEqualToString:@"go_home"]) {
        [gen menuPress];
        return @{ @"success" : @YES };
    }
    if ([a isEqualToString:@"unlock"]) {
        // 与 AKUN 一致：双 Home，不做上滑手势
        [gen menuPress];
        usleep(1200000);   // 与 AKUN 一致：等亮屏再按第二次 Home
        [gen menuPress];
        return @{ @"success" : @YES, @"via" : @"HID menuPress x2" };
    }
    if ([a isEqualToString:@"lock"]) {
        // 与 AKUN 一致：IOHIDEvent 电源键（powerPress），等效于按一下侧键锁屏
        [gen powerPress];
        return @{ @"success" : @YES, @"via" : @"HID powerPress" };
    }
    if ([a isEqualToString:@"restart_daemon"]) {
        return akunRestartDaemon();
    }
    if ([a isEqualToString:@"set_assistive_touch"]) {
        id v = cmd[@"enabled"];
        BOOL en = NO;
        if ([v isKindOfClass:[NSNumber class]]) {
            en = [v boolValue];
        } else if ([v isKindOfClass:[NSString class]]) {
            NSString *t = [(NSString *)v lowercaseString];
            en = [t isEqualToString:@"true"] || [t isEqualToString:@"on"] ||
                 [t isEqualToString:@"1"] || [t isEqualToString:@"yes"];
        } else {
            return @{ @"success" : @NO, @"error" : @"missing 'enabled' (true/false)" };
        }
        return akunApplyAssistiveTouch(en);
    }
    if ([a isEqualToString:@"assistive_touch_on"]) { return akunApplyAssistiveTouch(YES); }
    if ([a isEqualToString:@"assistive_touch_off"]) { return akunApplyAssistiveTouch(NO); }
    if ([a isEqualToString:@"ui_probe"]) {
        // 调试用：iOS 16.7.16 上辅助触控的球是 LaunchAngel
        // com.apple.AccessibilityUIServer 画的，launchctl kickstart 不支持 LaunchAngel（102）。
        // 这里直接以 mobile 身份 spawn 它，看能不能跑起来并把球画出来。
        NSMutableArray *cand = [NSMutableArray array];
        NSArray *paths = @[ @"/System/Library/CoreServices/AccessibilityUIServer.app/AccessibilityUIServer",
                            @"/rootfs/System/Library/CoreServices/AccessibilityUIServer.app/AccessibilityUIServer" ];
        pid_t pid = -1;
        int spawnRc = -1;
        NSString *used = @"";
        for (NSString *pth in paths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:pth]) { continue; }
            used = pth;
            char *cp = strdup(pth.UTF8String);
            char a1[] = "-NSDocumentRevisionsDebugMode";
            char a2[] = "YES";
            char *argv[] = { cp, a1, a2, NULL };
            posix_spawnattr_t at; posix_spawnattr_init(&at);
            posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP);
            posix_spawnattr_setpgroup(&at, 0);
            spawnRc = posix_spawn(&pid, cp, NULL, &at, argv, environ);
            posix_spawnattr_destroy(&at);
            break;
        }
        BOOL alive = NO;
        if (spawnRc == 0 && pid > 0) {
            usleep(1500 * 1000);
            alive = (kill(pid, 0) == 0);
        }
        [cand addObject:@{ @"path" : used.length ? used : @"(none)",
                           @"spawnRc" : @(spawnRc), @"pid" : @(pid), @"alive" : @(alive) }];
        NSLog(@"[aux] ui_probe %@ spawn=%d pid=%d alive=%d", used, spawnRc, (int)pid, alive);
        return @{ @"success" : @(alive), @"cand" : cand };
    }
    if ([a isEqualToString:@"get_assistive_touch"]) { return akunGetAssistiveTouch(); }
    if ([a isEqualToString:@"ax_notify"]) { return akunPostNotifications(cmd[@"names"]); }
    if ([a isEqualToString:@"respring"]) {
        // 与 AKUN 同构：交给 root 侧（这里的 dpkgd）杀 SpringBoard。
        // 主进程是 mobile，自己没权限动 SpringBoard，之前 posix_spawn killall 在 rootless 下会 ENOENT。
        int rc = -1;
        NSString *out = nil;
        akun_root_cmd(@"KILLSB", &rc, &out);
        return @{ @"success" : @(rc == 0),
                  @"via" : @"root SIGKILL SpringBoard",
                  @"detail" : (out ?: @""),
                  @"note" : @"SpringBoard 重启：画面黑一瞬后自己恢复，App 全部退出，重开是冷启动" };
    }
    if ([a isEqualToString:@"get_clipboard"]) {
        // AKUN 返回 text / changeCount / types；text 不是纯字符串时回 NSNull + note
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *s = nil;
        @try { s = pb.string; } @catch (__unused NSException *e) { s = nil; }
        NSInteger cc = pb.changeCount;
        NSArray *types = pb.pasteboardTypes ?: @[];
        if (![s isKindOfClass:[NSString class]]) {
            return @{ @"success" : @YES, @"text" : [NSNull null], @"changeCount" : @(cc),
                      @"types" : types, @"note" : @"no plain string on pasteboard" };
        }
        return @{ @"success" : @YES, @"text" : (s ?: @""), @"changeCount" : @(cc), @"types" : types };
    }
    if ([a isEqualToString:@"set_clipboard"]) {
        NSString *s = cmd[@"text"] ?: @"";
        if (!s.length) { return @{ @"success" : @NO, @"error" : @"missing text" }; }
        [UIPasteboard generalPasteboard].string = s;
        NSInteger cc = [UIPasteboard generalPasteboard].changeCount;
        return @{ @"success" : @YES, @"changeCount" : @(cc), @"length" : @(s.length) };
    }
    if ([a isEqualToString:@"input_text"]) {
        NSString *s = cmd[@"text"] ?: @"";
        if (!s.length) { return @{ @"success" : @NO, @"error" : @"empty text" }; }
        // AKUN 的做法：写剪贴板 → 键盘通道发 Cmd+V。中文也能进，因为走的是粘贴而不是逐字敲
        [UIPasteboard generalPasteboard].string = s;
        usleep(30000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:true];   // LeftGUI
        usleep(20000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0x19 isKeyDown:true];   // 'v'
        usleep(20000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0x19 isKeyDown:false];
        usleep(20000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:false];
        NSLog(@"[aux] input_text len=%lu", (unsigned long)s.length);
        return @{ @"success" : @YES };
    }
    if ([a isEqualToString:@"set_volume"] || [a isEqualToString:@"set_brightness"] ||
        [a isEqualToString:@"volume_up"] || [a isEqualToString:@"volume_down"] ||
        [a isEqualToString:@"toggle_mute"] || [a isEqualToString:@"brightness_up"] ||
        [a isEqualToString:@"brightness_down"]) {
        if ([a isEqualToString:@"volume_up"]) {
            // 与 AKUN 一致：HID 系统音量键（系统自己出 HUD、自己改音量）
            [gen volumeIncrementPress];
            usleep(200000);
            return @{ @"success" : @YES, @"via" : @"HID volumeIncrementPress", @"volume" : @(akun_get_volume()) };
        }
        if ([a isEqualToString:@"volume_down"]) {
            [gen volumeDecrementPress];
            usleep(200000);
            return @{ @"success" : @YES, @"via" : @"HID volumeDecrementPress", @"volume" : @(akun_get_volume()) };
        }
        if ([a isEqualToString:@"brightness_up"] || [a isEqualToString:@"brightness_down"]) {
            // 与 AKUN 一致：HID 系统亮度键，不做「读值 +0.1 再 setProperty」那套近似
            if ([a isEqualToString:@"brightness_up"]) { [gen displayBrightnessIncrementPress]; }
            else { [gen displayBrightnessDecrementPress]; }
            usleep(250000);
            return @{ @"success" : @YES, @"via" : @"HID brightnessPress",
                      @"brightness" : @((double)akun_get_brightness()) };
        }
        if ([a isEqualToString:@"set_volume"] || [a isEqualToString:@"toggle_mute"]) {
            float v = [cmd[@"value"] floatValue];
            if ([a isEqualToString:@"toggle_mute"]) { v = 0.0f; }
            Class avsc = NSClassFromString(@"AVSystemController");
            id shared = akun_msg0(avsc, @"sharedAVSystemController");
            SEL s = NSSelectorFromString(@"setVolumeTo:forCategory:");
            if (shared && [shared respondsToSelector:s]) {
                BOOL (*fn)(id, SEL, float, id) = (BOOL (*)(id, SEL, float, id))objc_msgSend;
                fn(shared, s, v, @"Audio/Video");
                usleep(250000);
                CGFloat rb = akun_get_volume();
                return @{ @"success" : @YES, @"volume" : @(v), @"readback" : @((double)rb),
                          @"applied" : @(fabsf((float)rb - v) < 0.06f) };
            }
            return @{ @"success" : @NO, @"error" : @"AVSystemController 不可用" };
        }
        CGFloat b = MAX(0.0, MIN(1.0, [cmd[@"value"] floatValue]));
        BOOL ok = akun_set_brightness(b);
        usleep(250000);
        CGFloat rb = akun_get_brightness();
        return @{ @"success" : @(ok), @"brightness" : @((double)b), @"readback" : @((double)rb),
                  @"applied" : @(fabs(rb - b) < 0.06),
                  @"via" : (ok ? @"BrightnessSystemClient" : @"UIScreen") };
    }
    if ([a isEqualToString:@"list_apps"] || [a isEqualToString:@"find_app"]) {
        // 1:1 对齐 AKUN TVNCAppListMatching：
        //   LS 的 allApplications 与 allInstalledApplications 都查（两个集合不完全相同）
        //   + 扫三个目录补漏 + 本地化名（InfoPlist.strings）+ type 只看 bundle 前缀 + 每项带 pid
        id ws = akun_appWorkspace();
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        if (ws) {
            for (NSString *selName in @[ @"allApplications", @"allInstalledApplications" ]) {
                SEL sel = NSSelectorFromString(selName);
                if (![ws respondsToSelector:sel]) continue;
                NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(ws, sel);
                if (![proxies isKindOfClass:[NSArray class]]) continue;
                for (id proxy in proxies) {
                    NSString *bid = akun_msg0(proxy, @"applicationIdentifier");
                    NSString *nm = akun_msg0(proxy, @"localizedName");
                    if (!bid.length) continue;
                    if (!nm.length) nm = bid;
                    if (map[bid]) continue;
                    map[bid] = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                bid, @"bundle", nm, @"name", nil];
                }
            }
        }
        akun_scan_app_bundles(@"/var/containers/Bundle/Application", map);
        akun_scan_app_bundles(@"/Applications", map);
        akun_scan_app_bundles(@"/rootfs/Applications", map);
        if (!map.count) { return @{ @"success" : @NO, @"error" : @"没有枚举到任何 App" }; }

        NSString *q = [cmd[@"name"] isKindOfClass:[NSString class]] ? [cmd[@"name"] lowercaseString] : nil;
        if ([a isEqualToString:@"find_app"] && !q.length) { return @{ @"success" : @NO, @"error" : @"missing name" }; }

        NSDictionary *procs = akun_proc_map();
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *bid in [[map allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
            NSMutableDictionary *item = [map[bid] mutableCopy];
            NSString *appPath = item[@"path"];
            [item removeObjectForKey:@"path"];
            // type 只按 bundle 前缀判定：LA 的 applicationType 会把 Filza/TrollStore 这些误报成 System
            item[@"type"] = [bid hasPrefix:@"com.apple."] ? @"System" : @"User";
            // 非苹果 App 读本地化真名，真实名进 name、原名留 alias（find_app 两个都能搜到）
            if (![bid hasPrefix:@"com.apple."] && appPath.length) {
                NSString *loc = akun_app_localized_name(appPath, item[@"name"]);
                if (loc.length && ![loc isEqualToString:item[@"name"]]) {
                    item[@"alias"] = item[@"name"];
                    item[@"name"] = loc;
                }
            }
            if (q.length) {
                NSString *nmLow = [(NSString *)item[@"name"] lowercaseString];
                NSString *alLow = [(NSString *)item[@"alias"] lowercaseString];
                BOOL hit = (nmLow.length && [nmLow rangeOfString:q].location != NSNotFound) ||
                           (alLow.length && [alLow rangeOfString:q].location != NSNotFound) ||
                           ([bid.lowercaseString rangeOfString:q].location != NSNotFound);
                if (!hit) continue;
            }
            NSString *ex = akun_bundle_exec(bid);
            NSNumber *pid = ex.length ? procs[ex] : nil;
            if (!pid && ex.length > 16) {
                NSString *pfx = [ex substringToIndex:16];
                for (NSString *k in procs) { if ([k hasPrefix:pfx]) { pid = procs[k]; break; } }
            }
            item[@"pid"] = @(pid ? pid.intValue : 0);
            [out addObject:item];
        }
        return @{ @"success" : @YES, @"apps" : out, @"count" : @(out.count) };
    }
    if ([a isEqualToString:@"launch_app"]) {
        id ws = akun_appWorkspace();
        NSString *bid = cmd[@"bundle"] ?: cmd[@"name"];
        if (!ws || !bid.length) { return @{ @"success" : @NO, @"error" : @"缺 bundle 或工作区不可用" }; }
        BOOL ok = akun_bool1(ws, @"openApplicationWithBundleID:", bid);
        if (!ok && [ws respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:options:")]) {
            SEL s2 = NSSelectorFromString(@"openApplicationWithBundleID:options:");
            BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            ok = fn(ws, s2, bid, @{});
        }
        return @{ @"success" : @(ok), @"bundle" : bid };
    }
    if ([a isEqualToString:@"open_url"]) {
        id ws = akun_appWorkspace();
        NSString *u = cmd[@"url"] ?: @"";
        NSURL *url = [NSURL URLWithString:u];
        if (!ws || !url) { return @{ @"success" : @NO, @"error" : @"缺 url 或工作区不可用" }; }
        BOOL ok = NO;
        if ([ws respondsToSelector:NSSelectorFromString(@"openURL:")]) {
            ok = akun_bool1(ws, @"openURL:", url);
        }
        if (!ok && [ws respondsToSelector:NSSelectorFromString(@"openSensitiveURL:withOptions:")]) {
            SEL s = NSSelectorFromString(@"openSensitiveURL:withOptions:");
            BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            ok = fn(ws, s, url, @{});
        }
        return @{ @"success" : @(ok), @"url" : u, @"via" : (ok ? @"LSApplicationWorkspace" : @"none") };
    }
    if ([a isEqualToString:@"kill_app"]) {
        NSString *bid = cmd[@"bundle"] ?: @"";
        if (!bid.length) { return @{ @"success" : @NO, @"error" : @"缺 bundle" }; }
        // AKUN 手法：不用 FBSSystemService（mobile 身份下 XPC 会无限等待卡死线程），
        // 直接按可执行名找 pid，SIGTERM → 0.5s 验 ESRCH → 不成再 SIGKILL → 0.2s 验
        NSString *ex = akun_bundle_exec(bid);
        if (!ex.length) { return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"拿不到 %@ 的可执行名", bid] }; }
        int pid = akun_pid_for_exec(ex);
        if (pid <= 0) { return @{ @"success" : @NO, @"error" : @"process not running (no pid)" }; }
        errno = 0;
        if (kill(pid, SIGTERM) == 0) {
            usleep(500000);
            errno = 0;
            if (kill(pid, 0) != 0 && errno == ESRCH) {
                NSLog(@"[aux] kill_app %@ -> SIGTERM(%d)", bid, pid);
                return @{ @"success" : @YES, @"bundle" : bid, @"via" : @"SIGTERM", @"pid" : @(pid) };
            }
        }
        errno = 0;
        if (kill(pid, SIGKILL) == 0) {
            usleep(200000);
            errno = 0;
            if (kill(pid, 0) != 0 && errno == ESRCH) {
                NSLog(@"[aux] kill_app %@ -> SIGKILL(%d)", bid, pid);
                return @{ @"success" : @YES, @"bundle" : bid, @"via" : @"SIGKILL", @"pid" : @(pid) };
            }
        }
        return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"kill(%d) failed, errno=%d", pid, errno] };
    }
    if ([a isEqualToString:@"probe_path"]) {
        // 调试用：daemon 视角下某路径是否存在/可读，不存在就逐级回退列出父目录状态。
        NSString *pth = cmd[@"path"] ?: @"";
        if (!pth.length) { return @{ @"success" : @NO, @"error" : @"缺 path" }; }
        NSFileManager *fm = [NSFileManager defaultManager];
        int stMode = akun_stat_mode(pth);
        BOOL ex = (stMode != -1);
        BOOL isDir = ex && S_ISDIR(stMode);
        NSMutableDictionary *r = [@{ @"success" : @YES, @"path" : pth, @"exists" : @(ex), @"isDir" : @(isDir) } mutableCopy];
        if (ex && !isDir) {
            NSData *pd = akun_fread_all(pth);
            r[@"fread_len"] = @(pd.length);
        }
        if (ex && !isDir) {
            NSDictionary *at = [fm attributesOfItemAtPath:pth error:nil];
            r[@"size"] = at[NSFileSize] ?: @0;
            NSData *d = akun_fread_all(pth);
            r[@"dataLen"] = @(d.length);
        } else if (ex) {
            NSArray *ls = [fm contentsOfDirectoryAtPath:pth error:nil];
            r[@"items"] = ls ?: @[];
        } else {
            NSMutableArray *chain = [NSMutableArray array];
            NSString *q = [pth stringByDeletingLastPathComponent];
            for (int i = 0; i < 8 && q.length > 1; i++) {
                BOOL d2 = NO;
                BOOL e2 = [fm fileExistsAtPath:q isDirectory:&d2];
                [chain addObject:[NSString stringWithFormat:@"%@ %d%@", q, e2, d2 ? @"(dir)" : @""]];
                if (e2) break;
                q = [q stringByDeletingLastPathComponent];
            }
            r[@"parents"] = chain;
        }
        r[@"home"] = NSHomeDirectory() ?: @"";
        r[@"tmpdir"] = NSTemporaryDirectory() ?: @"";
        r[@"uid"] = @(getuid());
        NSLog(@"[aux] probe_path %@", r);
        return r;
    }
    if ([a isEqualToString:@"list_packages"]) {
        // 不用 dpkg-query 子进程：rootless + mobile 身份下 posix_spawn 直接返回 ENOENT（rc=2），
        // 越狱环境下注入也会让外部二进制起不来。改成直读 dpkg 数据库（root:wheel 644，mobile 可读），
        // 字段与 AKUN 的 dpkg-query 输出同构（status 统一回 "ii" 已装态）。
        NSString *statusPath = @"root-dpkgd";
        NSString *diagTxt = @"";
        NSData *sd = akun_fetch_dpkg_tcp(19949);
        if (sd.length) {
            // dpkgd 回包格式：DIAG:...---STATUS---\n<status 原文>；只取后半段正文
            NSData *mark = [@"---STATUS---\n" dataUsingEncoding:NSUTF8StringEncoding];
            NSRange mr = [sd rangeOfData:mark options:0 range:NSMakeRange(0, sd.length)];
            if (mr.location != NSNotFound) {
                NSData *dh = [sd subdataWithRange:NSMakeRange(0, mr.location)];
                diagTxt = [[NSString alloc] initWithData:dh encoding:NSUTF8StringEncoding] ?: @"";
                NSUInteger off = NSMaxRange(mr);
                sd = (sd.length > off) ? [sd subdataWithRange:NSMakeRange(off, sd.length - off)] : nil;
            }
        }
        if (!sd.length) {
            statusPath = nil;
            for (NSString *p in @[ @"/var/mobile/Documents/akun_dpkg_status.txt", @"/tmp/akun_dpkg_status.txt", @"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status" ]) {
                NSData *d = akun_fread_all(p);
                if (d.length) { sd = d; statusPath = p; break; }
            }
        }
        if (!sd.length) { return @{ @"success" : @NO, @"error" : @"找不到 dpkg status", @"diag" : diagTxt }; }
        // dpkg status 里常混 latin1 字符（描述字段），整段按 UTF-8 解会直接返回 nil，
        // 于是 txt 为空、一包都解析不出来 —— 必须先 UTF-8 再回退 latin1。
        NSString *txt = [[NSString alloc] initWithData:sd encoding:NSUTF8StringEncoding];
        if (!txt.length) { txt = [[NSString alloc] initWithData:sd encoding:NSISOLatin1StringEncoding]; }
        if (!txt.length) { txt = @""; }
        NSMutableArray *out = [NSMutableArray array];
        NSInteger total = 0;
        for (NSString *stanza in [txt componentsSeparatedByString:@"\n\n"]) {
            if (!stanza.length) continue;
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
                NSRange r = [line rangeOfString:@":"];
                if (r.location == NSNotFound) continue;
                NSString *k = [line substringToIndex:r.location];
                NSString *v = [[line substringFromIndex:r.location + 1]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (!k.length) continue;
                kv[k] = v ?: @"";
            }
            NSString *s = kv[@"Status"] ?: @"";
            if (![s containsString:@"installed"]) continue;   // 只留已装态
            NSString *pkg = kv[@"Package"];
            if (!pkg.length) continue;
            total++;
            [out addObject:@{ @"package" : pkg,
                              @"version" : (kv[@"Version"] ?: @""),
                              @"arch" : (kv[@"Architecture"] ?: @""),
                              @"status" : @"ii",
                              @"section" : (kv[@"Section"] ?: @""),
                              @"essential" : (kv[@"Essential"] ?: @""),
                              @"priority" : (kv[@"Priority"] ?: @"") }];
        }
        return @{ @"success" : @YES, @"count" : @(out.count), @"total" : @(total),
                  @"bytes" : @(sd.length), @"packages" : out, @"source" : statusPath };
    }
    if ([a isEqualToString:@"delete_file"]) {
        NSString *p = cmd[@"path"] ?: @"";
        if (![p isKindOfClass:[NSString class]] || p.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (!akun_pkg_path_allowed(p)) {
            return @{ @"success" : @NO, @"error" : @"path not allowed (only .deb/.tipa/.ipa under /tmp/ or /var/mobile/)" };
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            return @{ @"success" : @YES, @"path" : p, @"deleted" : @NO, @"note" : @"file not exists" };
        }
        if (!akun_delete_pkg_file(p)) {
            return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"delete failed: %@", p] };
        }
        return @{ @"success" : @YES, @"path" : p, @"deleted" : @YES };
    }
    if ([a isEqualToString:@"key"]) {
        // 键盘通道：和 AKUN 一样走 HID 键盘事件。三种入参都能用：
        //   code  —— 具名键（enter/backspace/escape/tab/space/delete/up/down/left/right/home）
        //   char  —— 单个字符（a~z A~Z 0~9 及常见符号，需要 Shift 的自动带 Shift）
        //   text  —— 一串 ASCII，逐字符按下；中文/表情请用 input_text（走剪贴板粘贴）
        NSString *ch = cmd[@"char"];
        BOOL guiChar = [cmd[@"gui"] boolValue];
        if (ch.length == 1) {
            // gui=true 时按住 Cmd 再敲字符，用于 Cmd+C / Cmd+V / Cmd+A / Cmd+Z 这类组合键。
            if (guiChar) { [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:true]; usleep(20000); }
            [gen keyPress:ch];
            if (guiChar) { usleep(20000); [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:false]; }
            return @{ @"success" : @YES, @"char" : ch, @"gui" : @(guiChar) };
        }
        NSString *txt = cmd[@"text"];
        if (txt.length) {
            for (NSUInteger i = 0; i < txt.length; i++) {
                unichar c = [txt characterAtIndex:i];
                if (c > 0x7F) { continue; }   // 非 ASCII 交给 input_text
                [gen keyPress:[NSString stringWithFormat:@"%C", c]];
                usleep(15000);
            }
            return @{ @"success" : @YES, @"chars" : @(txt.length) };
        }
        NSString *k = cmd[@"code"] ?: @"";
        NSDictionary *map = @{ @"enter" : @0x28, @"backspace" : @0x2A, @"escape" : @0x29,
                               @"tab" : @0x2B, @"space" : @0x2C, @"delete" : @0x4C,
                               @"up" : @0x52, @"down" : @0x51, @"left" : @0x50, @"right" : @0x4F };
        NSNumber *n = map[k];
        if (!n) { return @{ @"success" : @NO, @"error" : @"未知按键" }; }
        BOOL gui = [cmd[@"gui"] boolValue];
        if (gui) { [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:true]; usleep(20000); }
        [gen _sendIOHIDKeyboardEvent:0x07 usage:n.unsignedIntValue isKeyDown:true];
        usleep(20000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:n.unsignedIntValue isKeyDown:false];
        if (gui) { usleep(20000); [gen _sendIOHIDKeyboardEvent:0x07 usage:0xE3 isKeyDown:false]; }
        return @{ @"success" : @YES, @"key" : k };
    }
    if ([a isEqualToString:@"upload_file"]) {
        // 与 AKUN 一致：分块上传，path/offset/size/data(base64)，一块一回
        NSString *path = cmd[@"path"];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (!akun_pkg_path_allowed(path)) {
            return @{ @"success" : @NO, @"error" : @"path must be an absolute .deb/.tipa/.ipa under /tmp/ or /var/mobile/" };
        }
        NSString *b64 = cmd[@"data"];
        NSData *chunk = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        if (!chunk.length) {
            return @{ @"success" : @NO, @"error" : @"missing data (base64)" };
        }
        NSInteger off = [cmd[@"offset"] integerValue];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (dir.length) { [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]; }
        NSError *err = nil;
        if (off <= 0 || ![fm fileExistsAtPath:path]) {
            [chunk writeToFile:path options:NSDataWritingAtomic error:&err];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [chunk writeToFile:path options:NSDataWritingAtomic error:&err];
            } else {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:chunk];
                    [fh closeFile];
                } @catch (NSException *e) { err = [NSError errorWithDomain:@"akun" code:1 userInfo:nil]; }
            }
        }
        if (err) { return @{ @"success" : @NO, @"error" : err.localizedDescription ?: @"write failed" }; }
        unsigned long long total = [[[fm attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize] unsignedLongLongValue];
        unsigned long long want = [cmd[@"size"] unsignedLongLongValue];
        BOOL complete = (want > 0) ? (total >= want) : YES;
        NSLog(@"[aux] upload_file %@ 收到 %llu/%llu", path.lastPathComponent, total, want);
        char rp[PATH_MAX]; NSString *real = @"";
        if (realpath(path.fileSystemRepresentation, rp)) real = [NSString stringWithUTF8String:rp];
        return @{ @"success" : @YES, @"path" : path, @"real" : real, @"bytes" : @(total), @"complete" : @(complete) };
    }
    if ([a isEqualToString:@"install_deb"]) {
        NSString *path = cmd[@"path"];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"文件不存在: %@", path] };
        }
        // daemon 是注入进程（mobile 身份），posix_spawn 外部二进制会 ENOENT；
        // 装包必须由 uid=0 的 dpkgd 代跑。
        NSString *out = nil;
        int rc = -1;
        NSData *local = [NSData dataWithContentsOfFile:path];
        if (!local.length) {
            return @{ @"success" : @NO, @"error" : @"daemon 读不到该文件", @"path" : path };
        }
        if (cmd[@"size"]) {
            unsigned long long want = [cmd[@"size"] unsignedLongLongValue];
            if (want && want != (unsigned long long)local.length) {
                return @{ @"success" : @NO,
                          @"error" : [NSString stringWithFormat:@"size mismatch: expected %llu, got %lu（包可能没传完）",
                                      want, (unsigned long)local.length],
                          @"path" : path };
            }
        }
        NSString *dest = @"@jb/var/mobile/Documents/akun_install.deb";
        const NSUInteger chunk = 8192;
        long long off = 0;
        while (off < (long long)local.length) {
            NSUInteger n = (NSUInteger)MIN((long long)chunk, (long long)local.length - off);
            NSData *piece = [local subdataWithRange:NSMakeRange((NSUInteger)off, n)];
            NSString *b64 = [piece base64EncodedStringWithOptions:0];
            NSString *head = [NSString stringWithFormat:@"PUTA %@ %lld %lu\n", dest, off, (unsigned long)b64.length];
            int prc = -1; NSString *po = nil;
            akun_root_cmd_body(head, [b64 dataUsingEncoding:NSUTF8StringEncoding], &prc, &po);
            if (prc != 0) {
                return @{ @"success" : @NO, @"error" : @"推送包到 root 侧失败", @"offset" : @(off),
                          @"detail" : (po ?: @""), @"path" : path };
            }
            off += (long long)n;
        }
        NSData *raw = akun_root_cmd([NSString stringWithFormat:@"DPKG_I %@", dest], &rc, &out);
        if (!raw.length) { return @{ @"success" : @NO, @"error" : @"dpkgd 未响应（19949 不通）", @"path" : path }; }
        NSString *shortOut = (out.length > 400) ? [out substringToIndex:400] : (out ?: @"");
        NSLog(@"[aux] install_deb rc=%d out=%@", rc, shortOut);
        NSMutableDictionary *res = [@{ @"success" : @(rc == 0), @"code" : @(rc),
                                       @"output" : (out ?: @""), @"path" : path,
                                       @"bytes" : @(local.length), @"via" : @"root-dpkgd",
                                       @"form" : @"deb" } mutableCopy];
        if (rc == 0) {
            // AKUN 装完会 SIGTERM SpringBoard 让新插件/新 deb 立即生效（respring:false 可关）
            BOOL wantRespring = (cmd[@"respring"] ? [cmd[@"respring"] boolValue] : YES);
            if (wantRespring) {
                int sbrc = -1; NSString *sbo = nil;
                akun_root_cmd(@"KILLSB", &sbrc, &sbo);
                res[@"respring"] = @(sbrc == 0);
                res[@"respring_detail"] = (sbo ?: @"");
            }
            // 装完清掉设备上的包，避免换名后越堆越多（keep_file:true 可留）
            BOOL keepFile = (cmd[@"keep_file"] ? [cmd[@"keep_file"] boolValue] : NO);
            if (!keepFile) {
                int drc = -1; NSString *dro = nil;
                akun_root_cmd([NSString stringWithFormat:@"DELE %@", dest], &drc, &dro);
            }
        }
        return res;
    }
    if ([a isEqualToString:@"uninstall_deb"]) {
        NSString *pkg = cmd[@"package"];
        if (![pkg isKindOfClass:[NSString class]] || pkg.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing package" };
        }
        NSString *out = nil;
        int rc = -1;
        NSData *raw = akun_root_cmd([NSString stringWithFormat:@"DPKG_R %@", pkg], &rc, &out);
        if (!raw.length) { return @{ @"success" : @NO, @"error" : @"dpkgd 未响应（19949 不通）", @"package" : pkg }; }
        NSLog(@"[aux] uninstall_deb %@ rc=%d", pkg, rc);
        return @{ @"success" : @(rc == 0), @"code" : @(rc), @"output" : (out ?: @""), @"package" : pkg, @"source" : @"root-dpkgd" };
    }
    if ([a isEqualToString:@"install_tipa"]) {
        // 1:1 对齐 AKUN TVNCInstallTipa：不自己解包，交给 TrollStore（它负责签名）
        NSString *path = cmd[@"path"];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (![path isAbsolutePath] || [path rangeOfString:@".."].location != NSNotFound) {
            return @{ @"success" : @NO, @"error" : @"invalid path" };
        }
        if (!([path hasPrefix:@"/tmp/"] || [path hasPrefix:@"/var/mobile/"])) {
            return @{ @"success" : @NO, @"error" : @"path must be under /tmp/ or /var/mobile/" };
        }
        NSString *lowerPath = path.lowercaseString;
        if (!([lowerPath hasSuffix:@".tipa"] || [lowerPath hasSuffix:@".ipa"])) {
            return @{ @"success" : @NO, @"error" : @"only .tipa/.ipa are accepted" };
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"file not found: %@", path] };
        }
        if (cmd[@"size"]) {
            long long want = [cmd[@"size"] longLongValue];
            long long have = (long long)[[fm attributesOfItemAtPath:path error:nil] fileSize];
            if (want > 0 && have != want) {
                return @{ @"success" : @NO,
                          @"error" : [NSString stringWithFormat:@"size mismatch: have %lld want %lld", have, want] };
            }
        }
        if (!akun_tipa_server_ensure()) {
            return @{ @"success" : @NO, @"error" : @"cannot start local http server on 127.0.0.1" };
        }
        gTipaPath = path;

        NSString *ext = path.pathExtension.lowercaseString;
        // URL 里统一用 ASCII 占位名：中文名 percent-encode 后交给 TrollStore 有二次解码风险，
        // 本机 HTTP 只服务"当前这一个文件"、不校验请求路径，叫什么无所谓，扩展名保住即可
        NSString *serveName = [NSString stringWithFormat:@"package.%@", ext.length ? ext : @"tipa"];
        NSString *u = [NSString stringWithFormat:@"apple-magnifier://install?url=http://127.0.0.1:%u/%@",
                       (unsigned)gTipaPort, serveName];

        id ws = akun_appWorkspace();
        NSURL *url = [NSURL URLWithString:u];
        BOOL ok = NO;
        if (ws && url) {
            if ([ws respondsToSelector:NSSelectorFromString(@"openURL:")]) {
                ok = akun_bool1(ws, @"openURL:", url);
            }
            if (!ok && [ws respondsToSelector:NSSelectorFromString(@"openSensitiveURL:withOptions:")]) {
                SEL s = NSSelectorFromString(@"openSensitiveURL:withOptions:");
                BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
                ok = fn(ws, s, url, @{});
            }
        }
        NSLog(@"[aux] install_tipa -> %@ opened=%d", u, ok);
        if (!ok) {
            return @{ @"success" : @NO, @"path" : path, @"url" : u,
                      @"error" : @"TrollStore unavailable: apple-magnifier:// 没人接管（未装巨魔？）" };
        }
        return @{ @"success" : @YES, @"path" : path, @"url" : u, @"port" : @(gTipaPort),
                  @"via" : @"TrollStore(apple-magnifier)",
                  @"note" : @"已在设备上交给 TrollStore，会弹安装确认框，需人工点一次 Install" };
    }
    if ([a isEqualToString:@"screenshot"]) {
        // 1:1 对齐 AKUN TVNCScreenshot：quality 是 0~100（默认 75），format = jpeg（默认）/ png，
        // 默认出原分辨率（scale=1）——中控拿到的像素要和 AKUN 一致，否则坐标/图色比对会错。
        double q = 75.0;
        if (cmd[@"quality"]) {
            q = [cmd[@"quality"] doubleValue];
            if (q <= 1.0) { q = q * 100.0; }     // 兼容老客户端的 0~1 传法
        }
        q = MAX(10.0, MIN(100.0, q));
        double sc = 1.0;
        if (cmd[@"scale"]) { sc = [cmd[@"scale"] doubleValue]; }
        BOOL asPNG = NO;
        NSString *fmt = cmd[@"format"];
        if ([fmt isKindOfClass:[NSString class]]) {
            NSString *lower = [fmt lowercaseString];
            if ([lower isEqualToString:@"png"] || [lower isEqualToString:@"lossless"]) asPNG = YES;
        }
        AkunCapture *cap = self.capture;
        if (!cap) { return @{ @"success" : @NO, @"error" : @"screenshot: 采集未就绪" }; }
        NSData *enc = [cap snapshotDataWithScale:sc quality:(q / 100.0) asPNG:asPNG];
        if (!enc) { return @{ @"success" : @NO, @"error" : @"screenshot: 渲染失败" }; }
        double pw = (double)cap.screenWidth * sc, ph = (double)cap.screenHeight * sc;
        return @{ @"success" : @YES,
                  @"format" : (asPNG ? @"png" : @"jpeg"),
                  @"data" : [enc base64EncodedStringWithOptions:0],
                  @"width" : @((int)pw),
                  @"height" : @((int)ph),
                  @"bytes" : @(enc.length),
                  @"quality" : @(q),
                  @"scale" : @(sc) };
    }
    return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"unhandled action: %@", a] };
}

@end
