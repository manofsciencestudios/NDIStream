#import "NDISender.h"
#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>
#include <os/lock.h>

@implementation NDISender {
    NDIlib_send_instance_t _sender;
    CVPixelBufferRef _heldBuffer;
    os_unfair_lock _lock;
}

- (nullable instancetype)initWithSourceName:(NSString *)name
                                 clockVideo:(BOOL)clockVideo {
    self = [super init];
    if (!self) return nil;

    if (![NDIRuntime ensureInitialized]) {
        return nil;
    }

    _lock = OS_UNFAIR_LOCK_INIT;

    NDIlib_send_create_t desc;
    desc.p_ndi_name = [name UTF8String];
    desc.p_groups = NULL;
    desc.clock_video = clockVideo ? true : false;
    desc.clock_audio = false;

    _sender = NDIlib_send_create(&desc);
    if (_sender == NULL) {
        return nil;
    }
    return self;
}

- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer
             frameRateN:(int32_t)frameRateN
             frameRateD:(int32_t)frameRateD {
    if (pixelBuffer == NULL) return;

    os_unfair_lock_lock(&_lock);
    if (_sender == NULL) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    CVReturn lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (lockResult != kCVReturnSuccess) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    if (!src) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        os_unfair_lock_unlock(&_lock);
        return;
    }

    OSType pf = CVPixelBufferGetPixelFormatType(pixelBuffer);
    NDIlib_FourCC_video_type_e fourCC;
    if (pf == kCVPixelFormatType_422YpCbCr8) {
        fourCC = NDIlib_FourCC_type_UYVY;
    } else {
        fourCC = NDIlib_FourCC_type_BGRA;
    }

    NDIlib_video_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.xres = (int)CVPixelBufferGetWidth(pixelBuffer);
    frame.yres = (int)CVPixelBufferGetHeight(pixelBuffer);
    frame.FourCC = fourCC;
    frame.frame_rate_N = frameRateN;
    frame.frame_rate_D = frameRateD;
    frame.picture_aspect_ratio = 0.0f;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = src;
    frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);

    CVPixelBufferRef previous = _heldBuffer;
    CVBufferRetain(pixelBuffer);
    _heldBuffer = pixelBuffer;

    NDIlib_send_send_video_async_v2(_sender, &frame);

    if (previous) {
        CVPixelBufferUnlockBaseAddress(previous, kCVPixelBufferLock_ReadOnly);
        CVBufferRelease(previous);
    }

    os_unfair_lock_unlock(&_lock);
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    if (_sender != NULL) {
        NDIlib_send_send_video_async_v2(_sender, NULL);
        if (_heldBuffer) {
            CVPixelBufferUnlockBaseAddress(_heldBuffer, kCVPixelBufferLock_ReadOnly);
            CVBufferRelease(_heldBuffer);
            _heldBuffer = NULL;
        }
        NDIlib_send_destroy(_sender);
        _sender = NULL;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)dealloc {
    [self stop];
}

@end
