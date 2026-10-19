#import "AecAudioPlugin.h"
#include "aec_engine.h"
#include <array>
#include <vector>
#include <cmath>

// Device-free processor. Playback belongs exclusively to the fork custom device;
// input comes exclusively from record. Main-platform-thread method calls serialize
// capture and the fork's actual render-reference events.
@interface AecAudioPlugin () {
 std::array<void*,4> _engines;
 NSMutableData *_pendingCapture,*_pendingReverse,*_trace,*_events;
 uint64_t _reverseBlocks,_captureSamples,_errors,_overrange;
 int _delay;
}
@end
@implementation AecAudioPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
 FlutterMethodChannel *c=[FlutterMethodChannel methodChannelWithName:@"aec_audio" binaryMessenger:registrar.messenger];
 [registrar addMethodCallDelegate:[AecAudioPlugin new] channel:c];
}
- (void)stop {for(auto &e:_engines){if(e)aec_destroy(e);e=nullptr;}}
- (void)dealloc {[self stop];}
- (NSDictionary*)stats {return @{@"reverseBlocks":@(_reverseBlocks),@"captureSamples":@(_captureSamples),@"dspErrors":@(_errors),@"conditionedOverrangeSamples":@(_overrange),@"referenceKind":@"fork output-only device renderReference; no capture or speaker owned by DSP"};}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
 NSDictionary *a=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:@{};
 if([call.method isEqual:@"configure"]){
  [self stop];_pendingCapture=[NSMutableData new];_pendingReverse=[NSMutableData new];_trace=[NSMutableData new];_events=[NSMutableData new];_reverseBlocks=_captureSamples=_errors=_overrange=0;_delay=[a[@"delayMs"]intValue];
  _engines={aec_create_config(1,0),nullptr,nullptr,nullptr};
  if(!_engines[0]){[self stop];result([FlutterError errorWithCode:@"aec" message:@"AEC allocation failed" details:nil]);return;}
  result([self stats]);return;
 }
 if([call.method isEqual:@"reverse"]){
  FlutterStandardTypedData *data=a[@"bytes"];if(!_engines[0]||![data isKindOfClass:FlutterStandardTypedData.class]||data.data.length%2){result([FlutterError errorWithCode:@"aec" message:@"Configure and supply PCM16" details:nil]);return;}
  [_pendingReverse appendData:data.data];
  while(_pendingReverse.length>=960){int16_t pcm[480];memcpy(pcm,_pendingReverse.bytes,960);[_pendingReverse replaceBytesInRange:NSMakeRange(0,960) withBytes:NULL length:0];for(auto e:_engines)if(e&&aec_reverse(e,pcm,480))++_errors;uint8_t kind=1;[_events appendBytes:&kind length:1];[_trace appendBytes:pcm length:960];++_reverseBlocks;}
  result(nil);return;
 }
 if([call.method isEqual:@"captureCompare"]){
  FlutterStandardTypedData *data=a[@"bytes"];if(!_engines[0]||![data isKindOfClass:FlutterStandardTypedData.class]||data.data.length%2){result([FlutterError errorWithCode:@"aec" message:@"Configure and supply PCM16" details:nil]);return;}
  [_pendingCapture appendData:data.data];NSMutableArray *output=[NSMutableArray new];for(int i=0;i<4;++i)[output addObject:[NSMutableData new]];
  while(_pendingCapture.length>=960){int16_t pcm[480],half[480],clean[480];memcpy(pcm,_pendingCapture.bytes,960);[_pendingCapture replaceBytesInRange:NSMakeRange(0,960) withBytes:NULL length:0];
   for(int k=0;k<480;++k){half[k]=(int16_t)std::lrint(pcm[k]*.5);if(std::abs((int)pcm[k])>4095)++_overrange;}
   for(int i=0;i<4;++i){if(!_engines[i])continue;if(aec_capture(_engines[i],i==3?half:pcm,clean,480,_delay))++_errors;[(NSMutableData*)output[i] appendBytes:clean length:960];}
   uint8_t kind=2;[_events appendBytes:&kind length:1];_captureSamples+=480;
  }
  result(@{@"baseline":[FlutterStandardTypedData typedDataWithBytes:output[0]],@"clockDrift":[FlutterStandardTypedData typedDataWithBytes:output[1]],@"conditioned":[FlutterStandardTypedData typedDataWithBytes:output[2]],@"headroom":[FlutterStandardTypedData typedDataWithBytes:output[3]]});return;
 }
 if([call.method isEqual:@"stats"]){result([self stats]);return;}
 if([call.method isEqual:@"freeze"]){result(nil);return;}
 if([call.method isEqual:@"renderTrace"]){result([FlutterStandardTypedData typedDataWithBytes:[_trace copy]]);return;}
 if([call.method isEqual:@"dspEvents"]){result([FlutterStandardTypedData typedDataWithBytes:[_events copy]]);return;}
 if([call.method isEqual:@"dispose"]){[self stop];result([self stats]);return;}
 result(FlutterMethodNotImplemented);
}
@end
