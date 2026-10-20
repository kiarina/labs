#import "PlayoutAudioPlugin.h"
#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <vector>
static std::atomic<int64_t> gBuffers{0}, gBytes{0}, gFrames{0}, gChannels{0}, gCalls{0};
#include "playout_pipeline.h"

// The received voice arrives from Dart (the fork's remote audio tap through the
// bridge's ReceivedAudio) as 48 kHz mono PCM16 and goes into the pipeline; the
// slot output is played through an application-owned AVAudioEngine. The PCM
// handed to that engine is the AEC reference.
@interface PlayoutAudioPlugin () {
  void* _pipeline;
  AVAudioEngine* _engine;
  AVAudioSourceNode* _node;
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
  [_engine stop];
  _engine = nil;
  _node = nil;
}

- (void)dispose {
  [self detach];
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
      @"primed" : @(s.primed),
      @"externalPendingSamples" : @(s.external_pending_samples),
      @"externalReturnedSamples" : @(s.external_returned_samples),
      @"externalPulledSamples" : @(s.external_pulled_samples),
      @"externalMaxPendingSamples" : @(s.external_max_pending_samples),
      @"externalDroppedSamples" : @(s.external_dropped_samples)
    };
    [m addEntriesFromDictionary:values];
  }
  m[@"engineRunning"] = @(_engine.isRunning);
  m[@"renderBuffers"] = @(gBuffers.load());
  m[@"renderBufferBytes"] = @(gBytes.load());
  m[@"renderBufferChannels"] = @(gChannels.load());
  m[@"renderFrames"] = @(gFrames.load());
  m[@"renderCalls"] = @(gCalls.load());
  m[@"outputFormat"] = _engine ? [[_engine.outputNode outputFormatForBus:0] description] : [NSNull null];
  m[@"nodeFormat"] = _node ? [[_node outputFormatForBus:0] description] : [NSNull null];
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
    result([self stats]);
    return;
  }
  if ([call.method isEqual:@"startSpeaker"]) {
    if (!_pipeline || _engine) {
      result([FlutterError errorWithCode:@"playout" message:@"configure first / already started" details:nil]);
      return;
    }
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
  if ([call.method isEqual:@"pushReceived"]) {
    FlutterStandardTypedData* data = a[@"bytes"];
    if (_pipeline && [data isKindOfClass:FlutterStandardTypedData.class])
      pipeline_received(_pipeline, (const int16_t*)data.data.bytes, (int)(data.data.length / 2), 1, 48000);
    result(nil);
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
  if ([call.method isEqual:@"pullExternal"]) {
    NSMutableData* d = [NSMutableData dataWithLength:48000 * 2];
    const int n = _pipeline ? pipeline_external_pull(_pipeline, (int16_t*)d.mutableBytes, 48000) : 0;
    d.length = n * 2;
    result([FlutterStandardTypedData typedDataWithBytes:d]);
    return;
  }
  if ([call.method isEqual:@"pushExternal"]) {
    FlutterStandardTypedData* data = a[@"bytes"];
    if (_pipeline && [data isKindOfClass:FlutterStandardTypedData.class])
      pipeline_external_push(_pipeline, (const int16_t*)data.data.bytes, (int)(data.data.length / 2));
    result(nil);
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
