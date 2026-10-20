#import "PlayoutAudioPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#include <atomic>
#include <vector>
static std::atomic<int64_t> gBuffers{0}, gBytes{0}, gFrames{0}, gChannels{0}, gCalls{0};
#include "playout_pipeline.h"

// Taps the decoded remote track before the mixer gain, mutes the native
// (fork custom device) playout by setting the remote source volume to 0, and
// plays the slot output through an application-owned AVAudioEngine. The PCM
// handed to that engine is the AEC reference.
@interface PlayoutRenderer : NSObject <RTCAudioRenderer>
@property(atomic) void* pipeline;
@property(nonatomic, strong) NSLock* lock;
@property(atomic) uint64_t callbacks;
@end
@implementation PlayoutRenderer
- (instancetype)init {
  if ((self = [super init])) _lock = [NSLock new];
  return self;
}
- (void)renderPCMBuffer:(AVAudioPCMBuffer*)buffer {
  int16_t* const* data = buffer.int16ChannelData;
  if (!data) return;
  [_lock lock];
  void* p = self.pipeline;
  if (p) {
    pipeline_received(p, data[0], (int)buffer.frameLength, (int)buffer.format.channelCount,
                      (int)buffer.format.sampleRate);
    self.callbacks = self.callbacks + 1;
  }
  [_lock unlock];
}
@end

@interface PlayoutAudioPlugin () {
  void* _pipeline;
  AVAudioEngine* _engine;
  AVAudioSourceNode* _node;
  RTCAudioTrack* _track;
  PlayoutRenderer* _renderer;
  double _previousVolume;
  std::vector<int16_t> _scratch;
}
@end

@implementation PlayoutAudioPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* c = [FlutterMethodChannel methodChannelWithName:@"playout_audio"
                                                        binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:[PlayoutAudioPlugin new] channel:c];
}

- (void)detach {
  if (_track && _renderer) [_track removeRenderer:_renderer];
  if (_renderer) {
    [_renderer.lock lock];
    _renderer.pipeline = nullptr;
    [_renderer.lock unlock];
  }
  [_engine stop];
  _engine = nil;
  _node = nil;
  _track = nil;
}

- (void)dispose {
  [self detach];
  _renderer = nil;
  if (_pipeline) pipeline_destroy(_pipeline);
  _pipeline = nullptr;
}
- (void)dealloc {
  [self dispose];
}

- (NSDictionary*)stats {
  NSMutableDictionary* m = [NSMutableDictionary new];
  if (_pipeline) {
    pipeline_stats s;
    pipeline_stats_get(_pipeline, &s);
    NSDictionary* values = @{
      @"receivedFrames" : @(s.received_frames), @"receivedRate" : @(s.received_rate),
      @"receivedChannels" : @(s.received_channels), @"slotBlocks" : @(s.slot_blocks),
      @"playedSamples" : @(s.played_samples), @"underflowSamples" : @(s.underflow_samples),
      @"overflowSamples" : @(s.overflow_samples), @"referenceBlocks" : @(s.reference_blocks),
      @"controlReferenceBlocks" : @(s.control_reference_blocks),
      @"captureSamples" : @(s.capture_samples), @"dspErrors" : @(s.dsp_errors),
      @"traceDroppedSamples" : @(s.trace_dropped_samples), @"queuedSamples" : @(s.queued_samples),
      @"slotMode" : @(s.slot_mode), @"slotLatencySamples" : @(s.slot_latency_samples),
      @"primed" : @(s.primed)
    };
    [m addEntriesFromDictionary:values];
  }
  m[@"rendererCallbacks"] = @(_renderer.callbacks);
  m[@"engineRunning"] = @(_engine.isRunning);
  m[@"renderBuffers"] = @(gBuffers.load());
  m[@"renderBufferBytes"] = @(gBytes.load());
  m[@"renderBufferChannels"] = @(gChannels.load());
  m[@"renderFrames"] = @(gFrames.load());
  m[@"renderCalls"] = @(gCalls.load());
  m[@"outputFormat"] = _engine ? [[_engine.outputNode outputFormatForBus:0] description] : [NSNull null];
  m[@"nodeFormat"] = _node ? [[_node outputFormatForBus:0] description] : [NSNull null];
  m[@"nativePlayoutVolume"] = _track ? @(_track.source.volume) : [NSNull null];
  m[@"previousNativeVolume"] = @(_previousVolume);
  m[@"referenceKind"] = @"PCM handed to the application AVAudioEngine (post-slot)";
  return m;
}

- (BOOL)startEngine:(NSError**)error {
  _engine = [AVAudioEngine new];
  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
  _scratch.assign(8192, 0);
  void* pipeline = _pipeline;
  int16_t* scratch = _scratch.data();
  _node = [[AVAudioSourceNode alloc]
      initWithFormat:format
         renderBlock:^OSStatus(BOOL* silent, const AudioTimeStamp* stamp, AVAudioFrameCount frames,
                               AudioBufferList* out) {
           gBuffers = out->mNumberBuffers;
           gBytes = out->mBuffers[0].mDataByteSize;
           gChannels = out->mBuffers[0].mNumberChannels;
           gFrames = frames;
           ++gCalls;
           float* dst = (float*)out->mBuffers[0].mData;
           AVAudioFrameCount done = 0;
           while (done < frames) {
             const int n = (int)MIN((AVAudioFrameCount)8192, frames - done);
             pipeline_render(pipeline, scratch, n);
             for (int i = 0; i < n; ++i) dst[done + i] = scratch[i] / 32768.f;
             done += n;
           }
           *silent = NO;
           return noErr;
         }];
  [_engine attachNode:_node];
  [_engine connect:_node to:_engine.mainMixerNode format:format];
  [_engine prepare];
  return [_engine startAndReturnError:error];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary* a = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqual:@"configure"]) {
    [self dispose];
    _pipeline = pipeline_create([a[@"delayMs"] intValue]);
    if (!_pipeline) {
      result([FlutterError errorWithCode:@"playout" message:@"pipeline allocation failed" details:nil]);
      return;
    }
    _renderer = [PlayoutRenderer new];
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"attachRemote"]) {
    if (!_pipeline || _track) {
      result([FlutterError errorWithCode:@"playout" message:@"configure first / already attached" details:nil]);
      return;
    }
    RTCMediaStreamTrack* t = [[FlutterWebRTCPlugin sharedSingleton] remoteTrackForId:a[@"trackId"]];
    if (![t isKindOfClass:RTCAudioTrack.class]) {
      result([FlutterError errorWithCode:@"playout" message:@"no remote audio track" details:a[@"trackId"]]);
      return;
    }
    _track = (RTCAudioTrack*)t;
    _previousVolume = _track.source.volume;
    // Mixer gain only: the renderer still receives the decoded PCM.
    _track.source.volume = 0;
    _renderer.pipeline = _pipeline;
    [_track addRenderer:_renderer];
    NSError* error = nil;
    if (![self startEngine:&error]) {
      [self detach];
      result([FlutterError errorWithCode:@"playout" message:@"speaker start failed"
                                 details:error.localizedDescription]);
      return;
    }
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"setMode"]) {
    if (_pipeline) pipeline_set_mode(_pipeline, [a[@"mode"] intValue]);
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"capture"]) {
    FlutterStandardTypedData* data = a[@"bytes"];
    if (!_pipeline || ![data isKindOfClass:FlutterStandardTypedData.class] || data.data.length % 2) {
      result([FlutterError errorWithCode:@"playout" message:@"configure and supply PCM16" details:nil]);
      return;
    }
    const int n = (int)(data.data.length / 2);
    const int capacity = n + 480;
    NSMutableData* post = [NSMutableData dataWithLength:capacity * 2];
    NSMutableData* pre = [NSMutableData dataWithLength:capacity * 2];
    const int written = pipeline_capture(_pipeline, (const int16_t*)data.data.bytes, n,
                                         (int16_t*)post.mutableBytes, (int16_t*)pre.mutableBytes, capacity);
    post.length = written * 2;
    pre.length = written * 2;
    result(@{@"post" : [FlutterStandardTypedData typedDataWithBytes:post],
             @"pre" : [FlutterStandardTypedData typedDataWithBytes:pre]});
    return;
  }
  if ([call.method isEqual:@"stats"]) {
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"traces"]) {
    NSMutableDictionary* m = [NSMutableDictionary new];
    NSArray* names = @[ @"received", @"reference", @"controlReference" ];
    for (int which = 0; which < 3 && _pipeline; ++which) {
      const int n = pipeline_trace(_pipeline, which, nullptr, 0);
      NSMutableData* d = [NSMutableData dataWithLength:n * 2];
      pipeline_trace(_pipeline, which, (int16_t*)d.mutableBytes, n);
      m[names[which]] = [FlutterStandardTypedData typedDataWithBytes:d];
    }
    if (_pipeline) {
      const int pairs = pipeline_clock_map(_pipeline, nullptr, 0);
      NSMutableData* d = [NSMutableData dataWithLength:pairs * 16];
      pipeline_clock_map(_pipeline, (int64_t*)d.mutableBytes, pairs);
      m[@"clockMap"] = [FlutterStandardTypedData typedDataWithBytes:d];
    }
    result(m);
    return;
  }
  if ([call.method isEqual:@"detach"]) {
    [self detach];
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"dispose"]) {
    NSDictionary* s = [self stats];
    [self dispose];
    result(s);
    return;
  }
  result(FlutterMethodNotImplemented);
}
@end
