#import "AecAudioPlugin.h"
#import <AVFoundation/AVFoundation.h>
#include "aec_engine.h"
#include <atomic>
#include <vector>

@interface AecAudioPlugin () {
 AVAudioEngine *_output;
 AVAudioSourceNode *_source;
 NSLock *_lock;
 NSMutableData *_render;
 NSMutableData *_capture;
 NSMutableData *_trace;
 void *_aec;
 int _delay;
 int16_t _reference[480];
 int _refCount;
 std::atomic<uint64_t> _played;
 std::atomic<uint64_t> _underflows;
 std::atomic<uint64_t> _reverse;
 uint64_t _captureSamples;
}
@end
@implementation AecAudioPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
 FlutterMethodChannel *channel=[FlutterMethodChannel methodChannelWithName:@"aec_audio" binaryMessenger:registrar.messenger];
 [registrar addMethodCallDelegate:[AecAudioPlugin new] channel:channel];
}
- (void)stop {
 [_output stop];_source=nil;_output=nil;
 if(_aec){aec_destroy(_aec);_aec=nullptr;}
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
 NSDictionary *a=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:@{};
 if([call.method isEqual:@"configure"]) {
  [self stop];_lock=[NSLock new];_render=[NSMutableData new];_capture=[NSMutableData new];_trace=[NSMutableData dataWithCapacity:11520000];
  _delay=[a[@"delayMs"]intValue];_aec=aec_create([a[@"enabled"]boolValue]);_refCount=0;
  _played=0;_underflows=0;_reverse=0;_captureSamples=0;
  if(!_aec){result([FlutterError errorWithCode:@"aec_create" message:@"AEC create failed" details:nil]);return;}
  NSError *error=nil;
#if TARGET_OS_IOS
  AVAudioSession *session=AVAudioSession.sharedInstance;
  [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDefaultToSpeaker|AVAudioSessionCategoryOptionMixWithOthers error:&error];
  if(!error)[session setPreferredSampleRate:48000 error:&error];
  if(!error)[session setActive:YES error:&error];
  if(!error)[session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
  if(error){result([FlutterError errorWithCode:@"session" message:error.description details:nil]);return;}
#endif
  _output=[AVAudioEngine new];
  AVAudioFormat *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:1];
  __weak AecAudioPlugin *weakSelf=self;
  _source=[[AVAudioSourceNode alloc]initWithFormat:format renderBlock:^OSStatus(BOOL *silence,const AudioTimeStamp *stamp,AVAudioFrameCount frames,AudioBufferList *buffers){
   AecAudioPlugin *self=weakSelf;if(!self)return noErr;
   (void)stamp;*silence=NO;
   std::vector<int16_t> pcm(frames,0);
   [self->_lock lock];NSUInteger available=MIN((NSUInteger)frames,self->_render.length/2);
   if(available){memcpy(pcm.data(),self->_render.bytes,available*2);[self->_render replaceBytesInRange:NSMakeRange(0,available*2) withBytes:NULL length:0];}
   [self->_lock unlock];self->_underflows.fetch_add(frames-available);
   for(UInt32 i=0;i<frames;i++) {
    int16_t sample=pcm[i];
    for(UInt32 c=0;c<buffers->mNumberBuffers;c++)((float*)buffers->mBuffers[c].mData)[i]=sample/32768.f;
    self->_reference[self->_refCount++]=sample;
    if(self->_refCount==480){aec_reverse(self->_aec,self->_reference,480);self->_reverse.fetch_add(1);self->_refCount=0;}
   }
   [self->_lock lock];if(self->_trace.length+frames*2<=11520000)[self->_trace appendBytes:pcm.data() length:frames*2];[self->_lock unlock];
   self->_played.fetch_add(frames);return noErr;
  }];
  [_output attachNode:_source];[_output connect:_source to:_output.mainMixerNode format:format];
  [_output startAndReturnError:&error];
  if(error){result([FlutterError errorWithCode:@"output" message:error.description details:nil]);return;}
  result(nil);
 }else if([call.method isEqual:@"render"]) {
  FlutterStandardTypedData *data=a[@"bytes"];
  if(!data||data.data.length%2){result([FlutterError errorWithCode:@"pcm" message:@"PCM16 required" details:nil]);return;}
  [_lock lock];
  if(_render.length+data.data.length>48000){[_render setLength:0];}
  [_render appendData:data.data];[_lock unlock];result(nil);
 }else if([call.method isEqual:@"capture"]) {
  FlutterStandardTypedData *data=a[@"bytes"];
  if(!_aec||!data||data.data.length%2){result([FlutterError errorWithCode:@"capture" message:@"Configure and supply PCM16" details:nil]);return;}
  [_capture appendData:data.data];NSMutableData *clean=[NSMutableData new];
  while(_capture.length>=960){int16_t in[480],out[480];memcpy(in,_capture.bytes,960);[_capture replaceBytesInRange:NSMakeRange(0,960) withBytes:NULL length:0];
   int code=aec_capture(_aec,in,out,480,_delay);if(code){result([FlutterError errorWithCode:@"aec_capture" message:@"DSP error" details:@(code)]);return;}[clean appendBytes:out length:960];_captureSamples+=480;
  }
  result([FlutterStandardTypedData typedDataWithBytes:clean]);
 }else if([call.method isEqual:@"stopRender"]) {
  [_lock lock];[_render setLength:0];[_lock unlock];result(nil);
 }else if([call.method isEqual:@"stats"]) {
  NSString *route=@"AVAudioEngine output";
#if TARGET_OS_IOS
  NSMutableArray *ports=[NSMutableArray new];
  for(AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs)[ports addObject:port.portType];
  route=[ports componentsJoinedByString:@","];
#endif
  result(@{@"playedFrames":@(_played.load()),@"underflowSamples":@(_underflows.load()),@"reverseFrames":@(_reverse.load()),@"captureSamples":@(_captureSamples),@"route":route,@"sampleRate":@48000,@"channels":@1});
 }else if([call.method isEqual:@"renderTrace"]) {[_lock lock];NSData *copy=[NSData dataWithData:_trace];[_lock unlock];result([FlutterStandardTypedData typedDataWithBytes:copy]);
 }else if([call.method isEqual:@"dispose"]) {[self stop];result(nil);}
 else result(FlutterMethodNotImplemented);
}
@end
