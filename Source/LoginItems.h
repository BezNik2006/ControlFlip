#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL CFLoginItemAPIAvailable(void);
FOUNDATION_EXPORT NSInteger CFLoginItemStatus(void);
FOUNDATION_EXPORT BOOL CFLoginItemSetEnabled(BOOL enabled, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void CFLoginItemOpenSettings(void);
NS_ASSUME_NONNULL_END
