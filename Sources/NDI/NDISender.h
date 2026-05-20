#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDISender : NSObject

- (nullable instancetype)initWithSourceName:(NSString *)name
                                 clockVideo:(BOOL)clockVideo;

- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer
             frameRateN:(int32_t)frameRateN
             frameRateD:(int32_t)frameRateD;

- (void)repeatLastFrameWithFrameRateN:(int32_t)frameRateN
                            frameRateD:(int32_t)frameRateD;

- (void)sendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer NS_SWIFT_NAME(sendAudio(_:));

- (void)stop;

@end

NS_ASSUME_NONNULL_END
