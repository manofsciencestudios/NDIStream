#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIFoundSource : NSObject
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *address;
- (instancetype)initWithName:(NSString *)name address:(NSString *)address;
@end

@interface NDIFinder : NSObject
+ (nullable instancetype)startNewFinder;
@property(nonatomic, copy, nullable) void (^onSourcesChanged)(NSArray<NDIFoundSource *> *sources);
- (NSArray<NDIFoundSource *> *)currentSources;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
