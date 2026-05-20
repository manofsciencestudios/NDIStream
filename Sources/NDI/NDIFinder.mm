#import "NDIFinder.h"
#import "NDIRuntime.h"
#include <Processing.NDI.Lib.h>
#include <atomic>

@implementation NDIFoundSource
- (instancetype)initWithName:(NSString *)name address:(NSString *)address {
    self = [super init];
    if (!self) return nil;
    _name = [name copy];
    _address = [address copy];
    return self;
}
@end

@implementation NDIFinder {
    NDIlib_find_instance_t _finder;
    std::atomic<bool> _stopFlag;
    NSArray<NDIFoundSource *> *_cachedSources;
    NSLock *_cacheLock;
    dispatch_queue_t _pollQueue;
}

+ (nullable instancetype)startNewFinder {
    return [[self alloc] initInternal];
}

- (nullable instancetype)initInternal {
    self = [super init];
    if (!self) return nil;

    if (![NDIRuntime ensureInitialized]) {
        return nil;
    }

    NDIlib_find_create_t desc;
    desc.show_local_sources = true;
    desc.p_groups = NULL;
    desc.p_extra_ips = NULL;

    _finder = NDIlib_find_create_v2(&desc);
    if (_finder == NULL) {
        return nil;
    }

    _stopFlag.store(false);
    _cachedSources = @[];
    _cacheLock = [[NSLock alloc] init];
    _pollQueue = dispatch_queue_create("NDIStream.NDIFinder.Poll", DISPATCH_QUEUE_SERIAL);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_pollQueue, ^{
        [weakSelf pollLoop];
    });

    return self;
}

- (void)pollLoop {
    while (!_stopFlag.load()) {
        bool changed = NDIlib_find_wait_for_sources(_finder, 1000);
        if (_stopFlag.load()) break;
        if (!changed) continue;

        uint32_t count = 0;
        const NDIlib_source_t *sources = NDIlib_find_get_current_sources(_finder, &count);

        NSMutableArray<NDIFoundSource *> *snapshot = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; i++) {
            NSString *name = sources[i].p_ndi_name
                ? [NSString stringWithUTF8String:sources[i].p_ndi_name]
                : @"";
            NSString *addr = sources[i].p_url_address
                ? [NSString stringWithUTF8String:sources[i].p_url_address]
                : @"";
            [snapshot addObject:[[NDIFoundSource alloc] initWithName:name address:addr]];
        }

        [_cacheLock lock];
        _cachedSources = [snapshot copy];
        NSArray<NDIFoundSource *> *delivered = _cachedSources;
        [_cacheLock unlock];

        void (^cb)(NSArray<NDIFoundSource *> *) = self.onSourcesChanged;
        if (cb) {
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(delivered);
            });
        }
    }
}

- (NSArray<NDIFoundSource *> *)currentSources {
    [_cacheLock lock];
    NSArray<NDIFoundSource *> *snapshot = _cachedSources;
    [_cacheLock unlock];
    return snapshot ?: @[];
}

- (void)stop {
    if (_stopFlag.exchange(true)) return;
    if (_pollQueue) {
        dispatch_sync(_pollQueue, ^{});
    }
    if (_finder != NULL) {
        NDIlib_find_destroy(_finder);
        _finder = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
