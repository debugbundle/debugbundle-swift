#import "DebugBundleObjCExceptionShim.h"
#import <objc/runtime.h>
#import <string.h>


// Metadata checks precede any potentially overridable Foundation accessor.
static BOOL DebugBundleKnownString(NSString *value) {
    if (value == nil) return YES;
    const char *name = class_getName(object_getClass(value));
    const char *known[] = {"NSString", "NSMutableString", "NSTaggedPointerString", "NSIndirectTaggedPointerString", "NSConstantString", "__NSCFConstantString", "__NSCFString", "Swift.__SharedStringStorage", "Swift.__StringStorage"};
    for (NSUInteger index = 0; index < sizeof(known) / sizeof(known[0]); index++) {
        if (strcmp(name, known[index]) == 0) return YES;
    }
    return NO;
}

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
        if (object_getClass(exception) != [NSException class]) {
            if (name != NULL) *name = @"NSException";
            if (reason != NULL) *reason = @"NSException details unavailable";
            if (stackTrace != NULL) *stackTrace = @[];
            return YES;
        }
        if (name != NULL) {
            NSString *value = exception.name;
            *name = DebugBundleKnownString(value) ? value : @"NSException";
        }
        if (reason != NULL) {
            NSString *value = exception.reason;
            *reason = DebugBundleKnownString(value) ? value : @"NSException details unavailable";
        }
        if (stackTrace != NULL) {
            *stackTrace = exception.callStackSymbols;
        }
        return YES;
    }
}
