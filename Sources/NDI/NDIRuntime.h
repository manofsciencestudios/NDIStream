#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIRuntime : NSObject
+ (BOOL)ensureInitialized;
+ (void)writeConfigLowestLatency:(BOOL)lowest;
+ (BOOL)isInitialized;
@end

NS_ASSUME_NONNULL_END
