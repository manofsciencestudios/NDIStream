#import "NDIReceiver.h"
#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>
#include <atomic>
#include <string.h>

static void NDIReceiverDebugLog(NSString *message) {
    @autoreleasepool {
        NSURL *desktop = [[NSFileManager defaultManager] URLsForDirectory:NSDesktopDirectory
                                                                 inDomains:NSUserDomainMask].firstObject;
        if (!desktop) {
            desktop = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"]
                                 isDirectory:YES];
        }
        NSURL *url = [desktop URLByAppendingPathComponent:@"NDIStream-debug.log"];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX";
        NSString *line = [NSString stringWithFormat:@"%@ [NDIReceiver.mm] %@\n",
                          [formatter stringFromDate:[NSDate date]],
                          message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            [@"NDIStream debug log\n\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
        }
        [handle closeFile];
    }
}

@implementation NDIReceiver {
    NDIlib_recv_instance_t _recv;
    std::atomic<bool> _stopFlag;
    std::atomic<bool> _cleanedUp;
    dispatch_queue_t _captureQueue;
    uint64_t _frameCounter;
}

- (nullable instancetype)initWithSourceName:(NSString *)sourceName
                              sourceAddress:(NSString *)sourceAddress {
    self = [super init];
    if (!self) return nil;

    if (![NDIRuntime ensureInitialized]) {
        return nil;
    }

    NDIlib_source_t src;
    memset(&src, 0, sizeof(src));
    NSData *nameData = [sourceName dataUsingEncoding:NSUTF8StringEncoding];
    NSData *addrData = [sourceAddress dataUsingEncoding:NSUTF8StringEncoding];
    src.p_ndi_name = (const char *)[nameData bytes];
    src.p_url_address = (addrData.length > 0) ? (const char *)[addrData bytes] : NULL;

    NDIlib_recv_create_v3_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.source_to_connect_to = src;
    desc.color_format = NDIlib_recv_color_format_fastest;
    desc.bandwidth = NDIlib_recv_bandwidth_highest;
    desc.allow_video_fields = false;
    desc.p_ndi_recv_name = NULL;

    _recv = NDIlib_recv_create_v3(&desc);
    if (_recv == NULL) {
        return nil;
    }

    _stopFlag.store(false);
    _cleanedUp.store(false);
    _frameCounter = 0;
    _captureQueue = dispatch_queue_create("NDIStream.NDIReceiver.Capture", DISPATCH_QUEUE_SERIAL);
    NDIReceiverDebugLog([NSString stringWithFormat:@"create source=%@ address=%@", sourceName, sourceAddress]);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_captureQueue, ^{
        [weakSelf captureLoop];
    });

    return self;
}

- (void)captureLoop {
    int consecutiveNoneCount = 0;
    NDIReceiverDebugLog(@"captureLoop start");
    while (!_stopFlag.load()) {
        NDIlib_video_frame_v2_t video;
        NDIlib_audio_frame_v3_t audio;
        memset(&video, 0, sizeof(video));
        memset(&audio, 0, sizeof(audio));

        NDIlib_frame_type_e type = NDIlib_recv_capture_v3(_recv, &video, &audio, NULL, 1000);
        if (_stopFlag.load()) {
            if (type == NDIlib_frame_type_video) {
                NDIlib_recv_free_video_v2(_recv, &video);
            }
            if (type == NDIlib_frame_type_audio) {
                NDIlib_recv_free_audio_v3(_recv, &audio);
            }
            break;
        }

        switch (type) {
            case NDIlib_frame_type_audio: {
                id<NDIReceiverDelegate> d = self.delegate;
                if (d && [d respondsToSelector:@selector(receiverDidReceiveAudio:sampleRate:channels:samplesPerChannel:channelStrideBytes:)]) {
                    [d receiverDidReceiveAudio:(const float *)audio.p_data
                                    sampleRate:audio.sample_rate
                                      channels:audio.no_channels
                             samplesPerChannel:audio.no_samples
                            channelStrideBytes:audio.channel_stride_in_bytes];
                }
                NDIlib_recv_free_audio_v3(_recv, &audio);
                break;
            }
            case NDIlib_frame_type_video: {
                if (consecutiveNoneCount > 0) {
                    NDIReceiverDebugLog([NSString stringWithFormat:@"video resumed after %d empty polls", consecutiveNoneCount]);
                    id<NDIReceiverDelegate> d = self.delegate;
                    if (d && [d respondsToSelector:@selector(receiverDidResume)]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [d receiverDidResume];
                        });
                    }
                }
                consecutiveNoneCount = 0;
                [self handleVideoFrame:&video];
                break;
            }
            case NDIlib_frame_type_none: {
                consecutiveNoneCount++;
                if (consecutiveNoneCount == 5 || consecutiveNoneCount % 15 == 0) {
                    NDIReceiverDebugLog([NSString stringWithFormat:@"no video polls=%d; keeping receiver alive", consecutiveNoneCount]);
                }
                if (consecutiveNoneCount >= 2) {
                    id<NDIReceiverDelegate> d = self.delegate;
                    if (d && [d respondsToSelector:@selector(receiverDidStallForSeconds:)]) {
                        NSInteger secs = (NSInteger)consecutiveNoneCount;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [d receiverDidStallForSeconds:secs];
                        });
                    }
                }
                break;
            }
            case NDIlib_frame_type_error: {
                NDIReceiverDebugLog(@"capture error; disconnecting");
                id<NDIReceiverDelegate> d = self.delegate;
                if (d) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [d receiverDidDisconnect];
                    });
                }
                _stopFlag.store(true);
                break;
            }
            default:
                consecutiveNoneCount = 0;
                break;
        }
    }
    NDIReceiverDebugLog(@"captureLoop exit");
}

- (void)handleVideoFrame:(NDIlib_video_frame_v2_t *)video {
    OSType cvPixelFormat = 0;
    BOOL supported = NO;
    switch (video->FourCC) {
        case NDIlib_FourCC_video_type_UYVY:
            cvPixelFormat = kCVPixelFormatType_422YpCbCr8;
            supported = YES;
            break;
        case NDIlib_FourCC_video_type_BGRA:
        case NDIlib_FourCC_video_type_BGRX:
            cvPixelFormat = kCVPixelFormatType_32BGRA;
            supported = YES;
            break;
        default:
            supported = NO;
            break;
    }

    if (!supported) {
        NDIReceiverDebugLog([NSString stringWithFormat:@"unsupported pixel format FourCC=0x%08x", (unsigned)video->FourCC]);
        NDIlib_recv_free_video_v2(_recv, video);
        return;
    }

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault,
                                      video->xres,
                                      video->yres,
                                      cvPixelFormat,
                                      (__bridge CFDictionaryRef)attrs,
                                      &pb);
    if (r != kCVReturnSuccess || pb == NULL) {
        NDIReceiverDebugLog([NSString stringWithFormat:@"CVPixelBufferCreate failed: %d", r]);
        NDIlib_recv_free_video_v2(_recv, video);
        return;
    }

    CVReturn lockResult = CVPixelBufferLockBaseAddress(pb, 0);
    if (lockResult != kCVReturnSuccess) {
        NDIReceiverDebugLog([NSString stringWithFormat:@"CVPixelBufferLockBaseAddress failed: %d", lockResult]);
        CVPixelBufferRelease(pb);
        NDIlib_recv_free_video_v2(_recv, video);
        return;
    }
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    if (!dst) {
        NDIReceiverDebugLog(@"CVPixelBufferGetBaseAddress returned NULL");
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CVPixelBufferRelease(pb);
        NDIlib_recv_free_video_v2(_recv, video);
        return;
    }
    size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
    size_t srcStride = (size_t)video->line_stride_in_bytes;
    size_t copyBytes = (dstStride < srcStride) ? dstStride : srcStride;
    if (dstStride == srcStride) {
        memcpy(dst, video->p_data, dstStride * (size_t)video->yres);
    } else {
        for (int y = 0; y < video->yres; y++) {
            memcpy(dst + y * dstStride, video->p_data + y * srcStride, copyBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    int32_t fpsN = (video->frame_rate_N > 0) ? video->frame_rate_N : 30000;
    int32_t fpsD = (video->frame_rate_D > 0) ? video->frame_rate_D : 1000;
    int w = video->xres;
    int h = video->yres;
    uint32_t fourCC = (uint32_t)video->FourCC;

    NDIlib_recv_free_video_v2(_recv, video);

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
    if (s != noErr || fmt == NULL) {
        NDIReceiverDebugLog([NSString stringWithFormat:@"CMVideoFormatDescriptionCreateForImageBuffer failed: %d", (int)s]);
        CVPixelBufferRelease(pb);
        return;
    }

    _frameCounter++;
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(fpsD, fpsN);
    timing.presentationTimeStamp = CMTimeMake((int64_t)_frameCounter * fpsD, fpsN);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sb = NULL;
    s = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pb,
        true,
        NULL, NULL,
        fmt,
        &timing,
        &sb);

    CFRelease(fmt);
    CVPixelBufferRelease(pb);

    if (s != noErr || sb == NULL) {
        NDIReceiverDebugLog([NSString stringWithFormat:@"CMSampleBufferCreateForImageBuffer failed: %d", (int)s]);
        return;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    id<NDIReceiverDelegate> d = self.delegate;
    if (d) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d receiverDidReceiveSampleBuffer:sb
                                        width:w
                                       height:h
                                   frameRateN:fpsN
                                   frameRateD:fpsD
                                       fourCC:fourCC];
            CFRelease(sb);
        });
    } else {
        CFRelease(sb);
    }
}

- (void)stop {
    NDIReceiverDebugLog(@"stop requested");
    _stopFlag.store(true);
    if (_cleanedUp.exchange(true)) return;
    if (_captureQueue) {
        dispatch_sync(_captureQueue, ^{});
    }
    if (_recv != NULL) {
        NDIlib_recv_destroy(_recv);
        _recv = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
