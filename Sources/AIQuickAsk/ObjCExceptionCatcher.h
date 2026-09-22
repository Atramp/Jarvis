#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 Objective-C 的 @try/@catch 桥给 Swift（Swift 无法捕获 NSException）。
/// 仅用于 RemoteViewCrashGuard 拦截 macOS 27 beta 的系统断言。
@interface ObjCExceptionCatcher : NSObject

/// 执行 tryBlock；若抛出 NSException 则返回之，正常结束返回 nil。
+ (nullable NSException *)catchException:(NS_NOESCAPE void (^)(void))tryBlock;

@end

NS_ASSUME_NONNULL_END
