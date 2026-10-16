#import "LoginItems.h"
#import <ServiceManagement/ServiceManagement.h>

// A thin binding to the public macOS 13+ API. Dynamic lookup also allows this
// personal project to compile with older Command Line Tools (SDK 11).
@protocol CFAppServiceInstance <NSObject>
@property (readonly) NSInteger status;
- (BOOL)registerAndReturnError:(NSError **)error;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

@protocol CFAppServiceFactory <NSObject>
+ (id<CFAppServiceInstance>)mainAppService;
+ (void)openSystemSettingsLoginItems;
@end

static Class<CFAppServiceFactory> CFServiceClass(void) {
    Class cls = NSClassFromString(@"SMAppService");
    return [cls respondsToSelector:@selector(mainAppService)] ? (Class<CFAppServiceFactory>)cls : Nil;
}

BOOL CFLoginItemAPIAvailable(void) { return CFServiceClass() != Nil; }

NSInteger CFLoginItemStatus(void) {
    Class<CFAppServiceFactory> cls = CFServiceClass();
    return cls ? [[cls mainAppService] status] : -1;
}

BOOL CFLoginItemSetEnabled(BOOL enabled, NSError **error) {
    Class<CFAppServiceFactory> cls = CFServiceClass();
    if (!cls) {
        if (error) *error = [NSError errorWithDomain:@"ControlFlip.LoginItems" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Автозапуск требует macOS 13 или новее."}];
        return NO;
    }
    id<CFAppServiceInstance> service = [cls mainAppService];
    return enabled ? [service registerAndReturnError:error] : [service unregisterAndReturnError:error];
}

void CFLoginItemOpenSettings(void) {
    Class<CFAppServiceFactory> cls = CFServiceClass();
    if ([cls respondsToSelector:@selector(openSystemSettingsLoginItems)]) [cls openSystemSettingsLoginItems];
}
