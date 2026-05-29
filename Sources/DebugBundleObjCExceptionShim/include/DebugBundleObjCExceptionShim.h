#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DebugBundleTryBlock)(void);

FOUNDATION_EXPORT BOOL DebugBundleCatchNSException(
    DebugBundleTryBlock tryBlock,
    NSString * __autoreleasing _Nullable * _Nullable name,
    NSString * __autoreleasing _Nullable * _Nullable reason,
    NSArray<NSString *> * __autoreleasing _Nullable * _Nullable stackTrace
);

NS_ASSUME_NONNULL_END