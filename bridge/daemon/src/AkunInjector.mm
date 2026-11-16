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
#import "AkunCapture.h"

// 全局：最后一次触摸注入的时刻（给抓屏侧算「点击→出帧」用）
double gLastInputMono = 0.0;

// 抓屏侧提供的「跟手升帧」钩子：每次注入输入就通知它，抓屏会在 1.2 秒内抬到 40fps
extern void AkunBridgeNoteInteraction(void);
#import "AkunOrientation.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdio.h>
#import <unistd.h>

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
static int akun_spawn_capture(NSArray<NSString *> *argv, NSString **outText) {
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
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    ssize_t n = 0;
    while ((n = read(fds[0], tmp, sizeof(tmp))) > 0) {
        if (buf.length + (NSUInteger)n > 16384) { n = (ssize_t)(16384 - buf.length); }
        if (n > 0) { [buf appendBytes:tmp length:(NSUInteger)n]; }
        if (buf.length >= 16384) { break; }
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
        if (usage == 0xE9) { [gen volumeIncrementPress]; }
        else if (usage == 0xEA) { [gen volumeDecrementPress]; }
        else if (usage == 0x223) { [gen menuPress]; }
    }
}


#pragma mark - 辅助功能（对标 AKUN 19940 指令集，传输仍走我们自己的 WS）

- (NSDictionary *)handleAux:(NSDictionary *)cmd {
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    NSString *a = cmd[@"a"] ?: cmd[@"action"];   // 兼容 AKUN 19940 风格 {"action":"xxx"}
    if (!a.length) { return @{ @"success" : @NO, @"error" : @"missing action" }; }

    if ([a isEqualToString:@"device_info"]) {
        UIDevice *d = [UIDevice currentDevice];
        NSString *name = d.name ?: @"iPhone";
        NSString *udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"";
        return @{ @"success" : @YES,
                  @"device_name" : name,
                  @"system_version" : d.systemVersion ?: @"",
                  @"model" : d.model ?: @"",
                  @"udid" : udid,
                  @"udid_source" : @"idfv",
                  @"form" : @"deb",
                  @"version" : @"1.0.0" };
    }
    if ([a isEqualToString:@"go_home"]) {
        [gen menuPress];
        return @{ @"success" : @YES };
    }
    if ([a isEqualToString:@"unlock"]) {
        // 与 AKUN 一致：双 Home，不做上滑手势
        [gen menuPress];
        usleep(200000);
        [gen menuPress];
        return @{ @"success" : @YES };
    }
    if ([a isEqualToString:@"lock"]) {
        // 电源键（HID KeyboardOrKeypad 0x30），等效于按一下侧键锁屏
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0x30 isKeyDown:true];
        usleep(30000);
        [gen _sendIOHIDKeyboardEvent:0x07 usage:0x30 isKeyDown:false];
        return @{ @"success" : @YES };
    }
    if ([a isEqualToString:@"respring"]) {
        // 重启 SpringBoard：daemon 是 root，直接 killall
        pid_t pid = 0;
        const char *argv[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
        return @{ @"success" : @YES, @"note" : @"respring 已发出" };
    }
    if ([a isEqualToString:@"get_clipboard"]) {
        NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
        return @{ @"success" : @YES, @"text" : s };
    }
    if ([a isEqualToString:@"set_clipboard"]) {
        NSString *s = cmd[@"text"] ?: @"";
        [UIPasteboard generalPasteboard].string = s;
        return @{ @"success" : @YES };
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
        if ([a isEqualToString:@"volume_up"]) { [gen volumeIncrementPress]; return @{ @"success" : @YES }; }
        if ([a isEqualToString:@"volume_down"]) { [gen volumeDecrementPress]; return @{ @"success" : @YES }; }
        if ([a isEqualToString:@"brightness_up"] || [a isEqualToString:@"brightness_down"]) {
            CGFloat cur = [UIScreen mainScreen].brightness;
            CGFloat next = [a isEqualToString:@"brightness_up"] ? cur + 0.1 : cur - 0.1;
            next = MAX(0.05, MIN(1.0, next));
            [UIScreen mainScreen].brightness = next;
            return @{ @"success" : @YES, @"brightness" : @(next) };
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
                return @{ @"success" : @YES, @"volume" : @(v) };
            }
            return @{ @"success" : @NO, @"error" : @"AVSystemController 不可用" };
        }
        CGFloat b = [cmd[@"value"] floatValue];
        [UIScreen mainScreen].brightness = MAX(0.05, MIN(1.0, b));
        return @{ @"success" : @YES, @"brightness" : @([UIScreen mainScreen].brightness) };
    }
    if ([a isEqualToString:@"list_apps"] || [a isEqualToString:@"find_app"]) {
        id ws = akun_appWorkspace();
        if (!ws) { return @{ @"success" : @NO, @"error" : @"LSApplicationWorkspace 不可用" }; }
        NSArray *apps = akun_msg0(ws, @"allInstalledApplications") ?: @[];
        NSString *q = cmd[@"name"];
        NSMutableArray *out = [NSMutableArray array];
        for (id app in apps) {
            NSString *bid = akun_msg0(app, @"applicationIdentifier");
            NSString *nm = akun_msg0(app, @"localizedName");
            if (!bid.length && !nm.length) { continue; }
            if (q.length) {
                BOOL hit = ([nm rangeOfString:q].location != NSNotFound) ||
                           ([bid rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound);
                if (!hit) { continue; }
            }
            [out addObject:@{ @"bundle" : bid ?: @"", @"name" : nm ?: @"" }];
            if (out.count >= 400) { break; }
        }
        return @{ @"success" : @YES, @"apps" : out, @"count" : @(out.count) };
    }
    if ([a isEqualToString:@"launch_app"]) {
        id ws = akun_appWorkspace();
        NSString *bid = cmd[@"bundle"] ?: cmd[@"name"];
        if (!ws || !bid.length) { return @{ @"success" : @NO, @"error" : @"缺 bundle 或工作区不可用" }; }
        BOOL ok = akun_bool1(ws, @"openApplicationWithBundleID:", bid);
        return @{ @"success" : @(ok), @"bundle" : bid };
    }
    if ([a isEqualToString:@"open_url"]) {
        id ws = akun_appWorkspace();
        NSString *u = cmd[@"url"] ?: @"";
        NSURL *url = [NSURL URLWithString:u];
        if (!ws || !url) { return @{ @"success" : @NO, @"error" : @"缺 url 或工作区不可用" }; }
        BOOL ok = NO;
        if ([ws respondsToSelector:NSSelectorFromString(@"openSensitiveURL:withOptions:")]) {
            SEL s = NSSelectorFromString(@"openSensitiveURL:withOptions:");
            BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            ok = fn(ws, s, url, @{});
        } else {
            ok = akun_bool1(ws, @"openURL:", url);
        }
        return @{ @"success" : @(ok), @"url" : u };
    }
    if ([a isEqualToString:@"kill_app"]) {
        NSString *bid = cmd[@"bundle"] ?: @"";
        if (!bid.length) { return @{ @"success" : @NO, @"error" : @"缺 bundle" }; }
        // 用 launchctl 的等价路径：直接找进程名不好使，这里走 SpringBoard 的常用私有选择器
        id ws = akun_appWorkspace();
        BOOL ok = akun_bool1(ws, @"terminateApplicationForBundleIdentifier:", bid);
        NSLog(@"[aux] kill_app %@ -> %d", bid, ok);
        return @{ @"success" : @(ok), @"bundle" : bid };
    }
    if ([a isEqualToString:@"list_packages"]) {
        // dpkg 状态库直读，避免依赖 rootd
        NSString *path = @"/var/lib/dpkg/status";
        NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!txt) { return @{ @"success" : @NO, @"error" : @"读不到 dpkg status" }; }
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *block in [txt componentsSeparatedByString:@"\n\n"]) {
            NSString *pkg = nil, *ver = nil, *status = nil;
            for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"Package: "]) { pkg = [line substringFromIndex:9]; }
                else if ([line hasPrefix:@"Version: "]) { ver = [line substringFromIndex:9]; }
                else if ([line hasPrefix:@"Status: "]) { status = [line substringFromIndex:8]; }
            }
            if (pkg.length) {
                [out addObject:@{ @"package" : pkg, @"version" : ver ?: @"", @"status" : status ?: @"" }];
            }
        }
        return @{ @"success" : @YES, @"packages" : out, @"count" : @(out.count) };
    }
    if ([a isEqualToString:@"delete_file"]) {
        NSString *p = cmd[@"path"] ?: @"";
        if (![p hasPrefix:@"/"]) { return @{ @"success" : @NO, @"error" : @"需要绝对路径" }; }
        BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        return @{ @"success" : @(ok), @"deleted" : @(ok) };
    }
    if ([a isEqualToString:@"key"]) {
        // 键盘通道：和 AKUN 一样走 HID 键盘事件。三种入参都能用：
        //   code  —— 具名键（enter/backspace/escape/tab/space/delete/up/down/left/right/home）
        //   char  —— 单个字符（a~z A~Z 0~9 及常见符号，需要 Shift 的自动带 Shift）
        //   text  —— 一串 ASCII，逐字符按下；中文/表情请用 input_text（走剪贴板粘贴）
        NSString *ch = cmd[@"char"];
        if (ch.length == 1) {
            [gen keyPress:ch];
            return @{ @"success" : @YES, @"char" : ch };
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
        return @{ @"success" : @YES, @"path" : path, @"bytes" : @(total), @"complete" : @(complete) };
    }
    if ([a isEqualToString:@"install_deb"]) {
        NSString *path = cmd[@"path"];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"文件不存在: %@", path] };
        }
        // 我们本身就是 root 的 LaunchDaemon，直接 dpkg -i，不需要 AKUN 那套独立 rootd
        NSString *dpkg = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/dpkg"]
                       ? @"/var/jb/usr/bin/dpkg" : @"/usr/bin/dpkg";
        NSString *out = nil;
        int rc = akun_spawn_capture(@[ dpkg, @"-i", path ], &out);
        NSLog(@"[aux] install_deb rc=%d out=%@", rc, [out substringToIndex:MIN(out.length, (NSUInteger)400)]);
        return @{ @"success" : @(rc == 0), @"code" : @(rc),
                  @"output" : (out ?: @""), @"path" : path };
    }
    if ([a isEqualToString:@"uninstall_deb"]) {
        NSString *pkg = cmd[@"package"];
        if (![pkg isKindOfClass:[NSString class]] || pkg.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing package" };
        }
        NSString *dpkg = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/dpkg"]
                       ? @"/var/jb/usr/bin/dpkg" : @"/usr/bin/dpkg";
        NSString *out = nil;
        int rc = akun_spawn_capture(@[ dpkg, @"-r", pkg ], &out);
        NSLog(@"[aux] uninstall_deb %@ rc=%d", pkg, rc);
        return @{ @"success" : @(rc == 0), @"code" : @(rc), @"output" : (out ?: @""), @"package" : pkg };
    }
    if ([a isEqualToString:@"install_tipa"]) {
        NSString *path = cmd[@"path"];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) {
            return @{ @"success" : @NO, @"error" : @"missing path" };
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"文件不存在: %@", path] };
        }
        // tipa 是 zip 包（内含 Payload/xxx.app）：解到 /Applications 再 uicache 刷图标
        NSString *out = nil;
        int rc = akun_spawn_capture(@[ @"/var/jb/usr/bin/unzip", @"-o", path, @"-d", @"/Applications" ], &out);
        if (rc != 0) {
            rc = akun_spawn_capture(@[ @"/usr/bin/unzip", @"-o", path, @"-d", @"/Applications" ], &out);
        }
        if (rc == 0) {
            akun_spawn_capture(@[ @"/var/jb/usr/bin/uicache", @"-a" ], NULL);
        }
        NSLog(@"[aux] install_tipa rc=%d", rc);
        return @{ @"success" : @(rc == 0), @"code" : @(rc), @"output" : (out ?: @""),
                  @"note" : @"tipa 走 /Applications 解包 + uicache；未签名应用需设备本身允许（TrollStore/已签名）" };
    }
    if ([a isEqualToString:@"screenshot"]) {
        // 与 AKUN 19940 对齐：{"action":"screenshot","quality":75}，回 base64 图片
        double q = 0.6;
        if (cmd[@"quality"]) {
            q = [cmd[@"quality"] doubleValue];
            if (q > 1.0) { q = q / 100.0; }   // AKUN 传 0~100，这里也认 0~1
        }
        double sc = 0.5;
        if (cmd[@"scale"]) { sc = [cmd[@"scale"] doubleValue]; }
        AkunCapture *cap = self.capture;
        if (!cap) { return @{ @"success" : @NO, @"error" : @"screenshot: 采集未就绪" }; }
        NSData *jpeg = [cap snapshotJPEGWithScale:sc quality:q];
        if (!jpeg) { return @{ @"success" : @NO, @"error" : @"screenshot: 渲染失败" }; }
        NSString *b64 = [jpeg base64EncodedStringWithOptions:0];
        return @{ @"success" : @YES, @"format" : @"jpeg", @"data" : b64,
                  @"bytes" : @(jpeg.length), @"scale" : @(sc) };
    }
    return @{ @"success" : @NO, @"error" : [NSString stringWithFormat:@"unhandled action: %@", a] };
}

@end
