#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSException *)catchException:(NS_NOESCAPE void (^)(void))tryBlock {
    @try {
        tryBlock();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
