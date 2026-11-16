#import <Foundation/Foundation.h>

/**
 触摸注入：在守护进程里直接向 HID 事件系统投递合成事件。

 与「注入 SpringBoard」的区别：本进程带 com.apple.private.hid.client.event-dispatch
 等权限，可以自己创建 IOHIDEventSystemClient 投事件，不需要往别的进程里注代码。
 */
@interface AkunInjector : NSObject

/// 坐标一律归一化（0~1），设备分辨率由注入端自己换算。
- (void)handleCommand:(NSDictionary *)cmd;

/// 辅助功能（对标 AKUN 19940 的动作集）：返回 {success, ...}，由上层回给网页。
- (NSDictionary *)handleAux:(NSDictionary *)cmd;

@end