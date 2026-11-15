#import "AkunDiscovery.h"

#import <sys/socket.h>
#import <sys/select.h>
#import <sys/ioctl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <errno.h>

static const uint16_t kDiscoveryPort = 19951;
static const uint16_t kHttpPort = 8080;
static NSString *const kProbePacket = @"AKUNBRIDGE_DISCOVER";

@implementation AkunDiscovery

#pragma mark - UDP 广播

+ (NSString *)discoverViaBroadcastWithTimeout:(NSTimeInterval)timeout {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        NSLog(@"[discover] socket 失败 errno=%d", errno);
        return nil;
    }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
    // 让它能收到广播回包，不必绑定到具体地址
    struct sockaddr_in bindAddr;
    memset(&bindAddr, 0, sizeof(bindAddr));
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_addr.s_addr = htonl(INADDR_ANY);
    bindAddr.sin_port = htons(0);
    if (bind(fd, (struct sockaddr *)&bindAddr, sizeof(bindAddr)) < 0) {
        NSLog(@"[discover] bind 失败 errno=%d", errno);
        close(fd);
        return nil;
    }

    NSData *probe = [kProbePacket dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<NSString *> *targets = [self broadcastAddresses];

    for (NSString *ip in targets) {
        struct sockaddr_in to;
        memset(&to, 0, sizeof(to));
        to.sin_family = AF_INET;
        to.sin_port = htons(kDiscoveryPort);
        inet_pton(AF_INET, ip.UTF8String, &to.sin_addr);
        ssize_t sent = sendto(fd, probe.bytes, probe.length, 0,
                              (struct sockaddr *)&to, sizeof(to));
        NSLog(@"[discover] 广播 -> %@:%u sent=%zd", ip, kDiscoveryPort, sent);
    }

    NSString *found = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    char buf[1024];

    while ([deadline timeIntervalSinceNow] > 0) {
        double remain = [deadline timeIntervalSinceNow];
        if (remain <= 0) { break; }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = (long)(remain * 1000000.0);

        int r = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (r <= 0) { break; }

        struct sockaddr_in from;
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &fromLen);
        if (n <= 0) { continue; }
        buf[n] = 0;

        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) { continue; }

        NSString *http = obj[@"http"];
        if (http.length == 0 && obj[@"port"]) {
            NSString *host = [NSString stringWithUTF8String:inet_ntoa(from.sin_addr)];
            http = [NSString stringWithFormat:@"http://%@:%@", host, obj[@"port"]];
        }
        if (http.length) {
            // 广播回包也要验一下是不是我们的服务（同网段可能有别的 8080 服务）
            if ([self isOurServerAt:http timeout:1.0]) {
                found = [http copy];
                NSLog(@"[discover] 广播命中：%@（对端 %s）", found, inet_ntoa(from.sin_addr));
                break;
            }
            NSLog(@"[discover] 广播回包 %@ 不是我们的服务，忽略", http);
        }
    }

    close(fd);
    return found;
}

/// 255.255.255.255 + 每个本机网卡对应的子网广播地址（有些路由器只放行子网广播）。
+ (NSArray<NSString *> *)broadcastAddresses {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithObject:@"255.255.255.255"];

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) { return out; }

    for (struct ifaddrs *a = addrs; a != NULL; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) { continue; }
        if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) { continue; }
        if (a->ifa_broadaddr) {
            char host[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *b = (struct sockaddr_in *)a->ifa_broadaddr;
            inet_ntop(AF_INET, &b->sin_addr, host, sizeof(host));
            NSString *ip = [NSString stringWithUTF8String:host];
            if (ip.length && ![ip isEqualToString:@"255.255.255.255"] && ![out containsObject:ip]) {
                [out addObject:ip];
                NSLog(@"[discover] 网卡 %s 子网广播 %@", a->ifa_name, ip);
            }
        }
    }
    freeifaddrs(addrs);
    return out;
}

#pragma mark - 网段扫描兜底

/// 只有回 /api/hello 且 app=akun-bridge 的才算我们的服务。
/// 之前只探 TCP 8080，会命中路由器管理页（真机上就扫到了 http://192.168.1.1:8080）。
+ (BOOL)isOurServerAt:(NSString *)base timeout:(NSTimeInterval)timeout {
    if (base.length == 0) { return NO; }
    NSString *urlString = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
    NSURL *url = [NSURL URLWithString:[urlString stringByAppendingString:@"api/hello"]];
    if (!url) { return NO; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                        cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                    timeoutInterval:timeout];
    __block NSData *payload = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                           completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length) { payload = data; }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));

    if (!payload.length) { return NO; }
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    BOOL ok = [obj isKindOfClass:[NSDictionary class]] &&
              [obj[@"app"] isEqualToString:@"akun-bridge"];
    if (!ok) {
        NSLog(@"[discover] %@ 的 /api/hello 不匹配：%@", base, obj);
    }
    return ok;
}

+ (NSString *)scanSubnetForHttp {
    NSString *localIP = [self primaryIPv4];
    if (!localIP) { return nil; }

    NSArray<NSString *> *parts = [localIP componentsSeparatedByString:@"."];
    if (parts.count != 4) { return nil; }
    NSString *prefix = [NSString stringWithFormat:@"%@.%@.%@.", parts[0], parts[1], parts[2]];
    NSString *selfHost = parts[3];

    NSLog(@"[discover] 广播没命中，开始扫 %@0/24 的 %u 端口", prefix, kHttpPort);

    for (int i = 1; i <= 254; i++) {
        if (i == selfHost.intValue) { continue; }
        NSString *ip = [prefix stringByAppendingFormat:@"%d", i];
        if (![self tcpProbe:ip port:kHttpPort timeoutMs:60]) { continue; }
        NSString *http = [NSString stringWithFormat:@"http://%@:%u", ip, kHttpPort];
        if ([self isOurServerAt:http timeout:0.8]) {
            NSLog(@"[discover] 网段扫描命中：%@", http);
            return http;
        }
        NSLog(@"[discover] %@ 端口开着但不是我们的服务，继续扫", http);
    }
    NSLog(@"[discover] 网段扫描也没找到");
    return nil;
}

+ (BOOL)tcpProbe:(NSString *)ip port:(uint16_t)port timeoutMs:(int)ms {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { return NO; }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, ip.UTF8String, &sa.sin_addr) != 1) {
        close(fd);
        return NO;
    }

    BOOL ok = NO;
    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (rc == 0) {
        ok = YES;
    } else if (errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = ms * 1000;
        if (select(fd + 1, NULL, &wfds, NULL, &tv) > 0) {
            int err = 0;
            socklen_t len = sizeof(err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                ok = YES;
            }
        }
    }
    close(fd);
    return ok;
}

+ (NSString *)primaryIPv4 {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) { return nil; }
    NSString *result = nil;
    for (struct ifaddrs *a = addrs; a != NULL; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) { continue; }
        if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) { continue; }
        char host[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
        inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host));
        NSString *ip = [NSString stringWithUTF8String:host];
        if (!ip.length) { continue; }
        // en0 是 Wi-Fi，优先用它
        if (strncmp(a->ifa_name, "en", 2) == 0) {
            result = ip;
            break;
        }
        if (!result) { result = ip; }
    }
    freeifaddrs(addrs);
    NSLog(@"[discover] 本机 IP = %@", result ?: @"(none)");
    return result;
}

#pragma mark - 对外

+ (NSString *)discoverServerWithTimeout:(NSTimeInterval)timeout {
    NSString *found = [self discoverViaBroadcastWithTimeout:timeout];
    if (found) { return found; }
    return [self scanSubnetForHttp];
}

@end
