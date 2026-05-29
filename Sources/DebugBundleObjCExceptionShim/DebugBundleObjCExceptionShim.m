#import "DebugBundleObjCExceptionShim.h"

BOOL DebugBundleCatchNSException(
    DebugBundleTryBlock tryBlock,
    NSString * __autoreleasing _Nullable * _Nullable name,
    NSString * __autoreleasing _Nullable * _Nullable reason,
    NSArray<NSString *> * __autoreleasing _Nullable * _Nullable stackTrace
) {
    @try {
        tryBlock();
        return NO;
    } @catch (NSException *exception) {
        if (name != NULL) {
            *name = exception.name;
        }
        if (reason != NULL) {
            *reason = exception.reason;
        }
        if (stackTrace != NULL) {
            *stackTrace = exception.callStackSymbols;
        }
        return YES;
    }
}