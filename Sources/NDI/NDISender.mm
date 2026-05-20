#import "NDISender.h"
#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <os/lock.h>
#include <vector>

@implementation NDISender {
    NDIlib_send_instance_t _sender;
    CVPixelBufferRef _heldBuffer;
    os_unfair_lock _lock;
}

- (nullable instancetype)initWithSourceName:(NSString *)name
                                 clockVideo:(BOOL)clockVideo {
    self = [super init];
    if (!self) return nil;

    _lock = OS_UNFAIR_LOCK_INIT;

    if (![NDIRuntime ensureInitialized]) {
        return nil;
    }

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
    } else if (pf == kCVPixelFormatType_32BGRA) {
        fourCC = NDIlib_FourCC_type_BGRA;
    } else {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        os_unfair_lock_unlock(&_lock);
        return;
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

- (void)sendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL) return;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (fmt == NULL) return;

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (asbd == NULL) return;
    if (asbd->mFormatID != kAudioFormatLinearPCM) return;

    const UInt32 channels = asbd->mChannelsPerFrame;
    const CMItemCount samples = CMSampleBufferGetNumSamples(sampleBuffer);
    if (channels == 0 || samples <= 0) return;

    size_t ablSize = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        &ablSize,
        NULL,
        0,
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        NULL);
    if (status != noErr || ablSize == 0) return;

    AudioBufferList *abl = (AudioBufferList *)malloc(ablSize);
    if (abl == NULL) return;

    CMBlockBufferRef blockBuffer = NULL;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        abl,
        ablSize,
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer);
    if (status != noErr) {
        free(abl);
        return;
    }

    const bool isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSignedInteger = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 bitsPerChannel = asbd->mBitsPerChannel;

    std::vector<float> planar((size_t)channels * (size_t)samples);
    bool converted = true;

    if (isNonInterleaved && abl->mNumberBuffers >= channels) {
        for (UInt32 ch = 0; ch < channels && converted; ch++) {
            const AudioBuffer &buffer = abl->mBuffers[ch];
            if (buffer.mData == NULL) {
                converted = false;
                break;
            }
            float *dst = planar.data() + ((size_t)ch * (size_t)samples);
            if (isFloat && bitsPerChannel == 32) {
                memcpy(dst, buffer.mData, (size_t)samples * sizeof(float));
            } else if (isSignedInteger && bitsPerChannel == 16) {
                const int16_t *src = (const int16_t *)buffer.mData;
                for (CMItemCount i = 0; i < samples; i++) dst[i] = (float)src[i] / 32768.0f;
            } else if (isSignedInteger && bitsPerChannel == 32) {
                const int32_t *src = (const int32_t *)buffer.mData;
                for (CMItemCount i = 0; i < samples; i++) dst[i] = (float)((double)src[i] / 2147483648.0);
            } else {
                converted = false;
            }
        }
    } else if (!isNonInterleaved && abl->mNumberBuffers >= 1 && abl->mBuffers[0].mData != NULL) {
        if (isFloat && bitsPerChannel == 32) {
            const float *src = (const float *)abl->mBuffers[0].mData;
            for (CMItemCount i = 0; i < samples; i++) {
                for (UInt32 ch = 0; ch < channels; ch++) {
                    planar[(size_t)ch * (size_t)samples + (size_t)i] = src[(size_t)i * channels + ch];
                }
            }
        } else if (isSignedInteger && bitsPerChannel == 16) {
            const int16_t *src = (const int16_t *)abl->mBuffers[0].mData;
            for (CMItemCount i = 0; i < samples; i++) {
                for (UInt32 ch = 0; ch < channels; ch++) {
                    planar[(size_t)ch * (size_t)samples + (size_t)i] = (float)src[(size_t)i * channels + ch] / 32768.0f;
                }
            }
        } else if (isSignedInteger && bitsPerChannel == 32) {
            const int32_t *src = (const int32_t *)abl->mBuffers[0].mData;
            for (CMItemCount i = 0; i < samples; i++) {
                for (UInt32 ch = 0; ch < channels; ch++) {
                    planar[(size_t)ch * (size_t)samples + (size_t)i] = (float)((double)src[(size_t)i * channels + ch] / 2147483648.0);
                }
            }
        } else {
            converted = false;
        }
    } else {
        converted = false;
    }

    if (blockBuffer) CFRelease(blockBuffer);
    free(abl);

    if (!converted) return;

    NDIlib_audio_frame_v3_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.sample_rate = (int)lrint(asbd->mSampleRate);
    frame.no_channels = (int)channels;
    frame.no_samples = (int)samples;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.FourCC = NDIlib_FourCC_audio_type_FLTP;
    frame.p_data = (uint8_t *)planar.data();
    frame.channel_stride_in_bytes = (int)((size_t)samples * sizeof(float));

    os_unfair_lock_lock(&_lock);
    if (_sender != NULL) {
        NDIlib_send_send_audio_v3(_sender, &frame);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)repeatLastFrameWithFrameRateN:(int32_t)frameRateN
                            frameRateD:(int32_t)frameRateD {
    os_unfair_lock_lock(&_lock);
    if (_sender == NULL || _heldBuffer == NULL) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(_heldBuffer);
    if (!src) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    OSType pf = CVPixelBufferGetPixelFormatType(_heldBuffer);
    NDIlib_FourCC_video_type_e fourCC;
    if (pf == kCVPixelFormatType_422YpCbCr8) {
        fourCC = NDIlib_FourCC_type_UYVY;
    } else if (pf == kCVPixelFormatType_32BGRA) {
        fourCC = NDIlib_FourCC_type_BGRA;
    } else {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    NDIlib_video_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.xres = (int)CVPixelBufferGetWidth(_heldBuffer);
    frame.yres = (int)CVPixelBufferGetHeight(_heldBuffer);
    frame.FourCC = fourCC;
    frame.frame_rate_N = frameRateN;
    frame.frame_rate_D = frameRateD;
    frame.picture_aspect_ratio = 0.0f;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = src;
    frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(_heldBuffer);

    NDIlib_send_send_video_async_v2(_sender, &frame);
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
