#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIRuntime : NSObject
+ (BOOL)ensureInitialized;
+ (void)writeConfigLowestLatency:(BOOL)lowest;
@end

NS_ASSUME_NONNULL_END
