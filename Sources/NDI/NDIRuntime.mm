#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>
#include <stdlib.h>

static NSString *const kLowestLatencyDefaultsKey = @"lowestLatency";

@implementation NDIRuntime

+ (NSString *)configDirectory {
    NSURL *appSupport = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil
                                                                  create:YES
                                                                   error:nil];
    NSURL *dir = [appSupport URLByAppendingPathComponent:@"NDIStream/ndi-config" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return dir.path;
}

+ (void)writeConfigLowestLatency:(BOOL)lowest {
    NSString *dir = [self configDirectory];
    if (dir == nil) return;
    NSString *path = [dir stringByAppendingPathComponent:@"ndi-config.v1.json"];
    NSDictionary *config = @{
        @"ndi": @{
            @"rudp":    @{ @"send": @{ @"enable": lowest ? @NO  : @YES } },
            @"unicast": @{ @"send": @{ @"enable": lowest ? @YES : @NO  } }
        }
    };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (data) {
        [data writeToFile:path atomically:YES];
    }
    setenv("NDI_CONFIG_DIR", [dir fileSystemRepresentation], 1);
}

+ (BOOL)ensureInitialized {
    static dispatch_once_t onceToken;
    static BOOL ok = NO;
    dispatch_once(&onceToken, ^{
        BOOL lowest = [[NSUserDefaults standardUserDefaults] boolForKey:kLowestLatencyDefaultsKey];
        [self writeConfigLowestLatency:lowest];
        ok = NDIlib_initialize();
    });
    return ok;
}

@end
