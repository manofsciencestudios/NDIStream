#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@protocol NDIReceiverDelegate <NSObject>
- (void)receiverDidReceiveSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                 width:(int)width
                                height:(int)height
                            frameRateN:(int)frameRateN
                            frameRateD:(int)frameRateD
                                fourCC:(uint32_t)fourCC;
- (void)receiverDidDisconnect;
@optional
- (void)receiverDidStallForSeconds:(NSInteger)seconds;
- (void)receiverDidResume;
- (void)receiverDidReceiveAudio:(const float *)samples
                     sampleRate:(int)sampleRate
                       channels:(int)channels
              samplesPerChannel:(int)samplesPerChannel
             channelStrideBytes:(int)channelStrideBytes;
@end

@interface NDIReceiver : NSObject
- (nullable instancetype)initWithSourceName:(NSString *)sourceName
                              sourceAddress:(NSString *)sourceAddress;
@property(nonatomic, weak, nullable) id<NDIReceiverDelegate> delegate;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
