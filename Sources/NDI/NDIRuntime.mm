#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>

@implementation NDIRuntime

+ (BOOL)ensureInitialized {
    static dispatch_once_t onceToken;
    static BOOL ok = NO;
    dispatch_once(&onceToken, ^{
        ok = NDIlib_initialize();
    });
    return ok;
}

@end
