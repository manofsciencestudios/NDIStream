#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDISender : NSObject

- (nullable instancetype)initWithSourceName:(NSString *)name
                                 clockVideo:(BOOL)clockVideo;

- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer
             frameRateN:(int32_t)frameRateN
             frameRateD:(int32_t)frameRateD;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
