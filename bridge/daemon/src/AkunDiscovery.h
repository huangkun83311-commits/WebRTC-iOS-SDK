//  局域网自动发现 —— 手机侧不用手填 IP。
//
//  两级策略，和 AKUN 那套的习惯保持一致：
//   1. UDP 19941 广播探测包，电脑端中继回一条 {"akun":true,"http":"http://ip:port"}；
//   2. 广播被路由器/系统拦掉时，退化成扫本机所在 /24 网段的 8080 端口（TCP 连接探测）。
#import <Foundation/Foundation.h>

@interface AkunDiscovery : NSObject

/// 返回形如 http://192.168.1.100:8080 的地址；找不到返回 nil。
/// timeout 是 UDP 广播的总等待时间，超时后再走网段扫描（扫描自身最多约 8 秒）。
+ (NSString *)discoverServerWithTimeout:(NSTimeInterval)timeout;

/// 只做 UDP 广播那一级，给需要频繁重试的场景用。
+ (NSString *)discoverViaBroadcastWithTimeout:(NSTimeInterval)timeout;

@end
