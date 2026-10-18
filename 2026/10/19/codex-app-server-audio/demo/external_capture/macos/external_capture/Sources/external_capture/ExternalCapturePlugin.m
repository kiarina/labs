#import "ExternalCapturePlugin.h"
#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalVideoTrack.h>
#import <flutter_webrtc/LocalAudioTrack.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>

// External PCM input with audible AVAudioEngine output. record owns capture.
// Headphones are required for this feasibility app; AEC is not implemented.
@interface ExternalAudioDevice : NSObject<RTCAudioDevice> {
  AVAudioEngine *_engine;
  AVAudioPlayerNode *_player;
  AVAudioFormat *_format;
  atomic_int _queued;
  NSLock *_lock;
  NSMutableData *_pending;
  NSThread *_thread;
  atomic_bool _stop;
  atomic_bool _recording;
  atomic_bool _playing;
}
@property(nonatomic,strong) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic) BOOL isInitialized;
@property(nonatomic) BOOL isPlayoutInitialized;
@property(nonatomic) BOOL isRecordingInitialized;
@property(nonatomic) NSUInteger receivedBytes;
@property(nonatomic) NSUInteger droppedBytes;
@property(nonatomic) NSUInteger deliveredBlocks;
@property(nonatomic) NSUInteger underflows;
@property(nonatomic) BOOL outputEnabled;
@property(nonatomic) NSUInteger outputNonzeroSamples;
@property(nonatomic) NSUInteger outputCompletedBuffers;
- (void)enqueue:(NSData *)data;
- (void)clear;
@end
@implementation ExternalAudioDevice
- (instancetype)init { if ((self=[super init])) { _lock=[NSLock new];_pending=[NSMutableData new];atomic_init(&_stop,false);atomic_init(&_recording,false);atomic_init(&_playing,false);atomic_init(&_queued,0);self.outputEnabled=YES; } return self; }
- (double)deviceInputSampleRate{return 48000;}
- (double)deviceOutputSampleRate{return 48000;}
- (NSTimeInterval)inputIOBufferDuration{return .01;}
- (NSTimeInterval)outputIOBufferDuration{return .01;}
- (NSInteger)inputNumberOfChannels{return 1;}
- (NSInteger)outputNumberOfChannels{return 1;}
- (NSTimeInterval)inputLatency{return .1;}
- (NSTimeInterval)outputLatency{return .01;}
- (BOOL)isRecording{return atomic_load(&_recording);}
- (BOOL)isPlaying{return atomic_load(&_playing);}
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
 self.delegate=delegate;self.isInitialized=YES;atomic_store(&_stop,false);
 _thread=[[NSThread alloc]initWithTarget:self selector:@selector(pump) object:nil];[_thread start];return YES;
}
- (BOOL)terminateDevice{atomic_store(&_stop,true);self.isInitialized=NO;return YES;}
- (BOOL)initializePlayout{self.isPlayoutInitialized=YES;return YES;}
- (BOOL)initializeRecording{self.isRecordingInitialized=YES;return YES;}
- (BOOL)startPlayout{
 if(!_engine){_engine=[AVAudioEngine new];_player=[AVAudioPlayerNode new];_format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:1];[_engine attachNode:_player];[_engine connect:_player to:_engine.mainMixerNode format:_format];}
 NSError *error=nil;[_engine startAndReturnError:&error];if(error)return NO;[_player play];atomic_store(&_playing,true);return YES;
}
- (BOOL)stopPlayout{atomic_store(&_playing,false);[_player stop];[_engine stop];return YES;}
- (BOOL)startRecording{atomic_store(&_recording,true);return YES;}
- (BOOL)stopRecording{atomic_store(&_recording,false);[self clear];return YES;}
- (void)clear{[_lock lock];[_pending setLength:0];[_lock unlock];}
- (void)enqueue:(NSData *)data {
 [_lock lock];self.receivedBytes+=data.length;
 if(data.length>19200){ self.droppedBytes+=data.length-19200;data=[data subdataWithRange:NSMakeRange(data.length-19200,19200)]; }
 if(_pending.length+data.length>19200){NSUInteger n=_pending.length+data.length-19200;self.droppedBytes+=n;[_pending replaceBytesInRange:NSMakeRange(0,n) withBytes:NULL length:0];}
 [_pending appendData:data];[_lock unlock];
}
- (void)pump {
 @autoreleasepool {
 double next=NSProcessInfo.processInfo.systemUptime;
 while(!atomic_load(&_stop)) {
  @autoreleasepool {
   int16_t pcm[480]={0},out[480]={0};AudioTimeStamp stamp={0};stamp.mFlags=kAudioTimeStampSampleTimeValid;stamp.mSampleTime=self.deliveredBlocks*480;
   AudioUnitRenderActionFlags flags=0;
   if(atomic_load(&_recording)) {
    [_lock lock];if(_pending.length>=sizeof(pcm)){memcpy(pcm,_pending.bytes,sizeof(pcm));[_pending replaceBytesInRange:NSMakeRange(0,sizeof(pcm)) withBytes:NULL length:0];}else{self.underflows++;}[_lock unlock];
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=sizeof(pcm),.mData=pcm}}};
    self.delegate.deliverRecordedData(&flags,&stamp,0,480,&list,NULL,nil);self.deliveredBlocks++;
   }
   if(atomic_load(&_playing)) {
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=sizeof(out),.mData=out}}};
    self.delegate.getPlayoutData(&flags,&stamp,0,480,&list);
    for(int i=0;i<480;i++)if(out[i])self.outputNonzeroSamples++;
    if(atomic_load(&_queued)<20){AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc]initWithPCMFormat:_format frameCapacity:480];buffer.frameLength=480;for(int i=0;i<480;i++)buffer.floatChannelData[0][i]=self.outputEnabled?out[i]/32768.0f:0;atomic_fetch_add(&_queued,1);[_player scheduleBuffer:buffer completionHandler:^{atomic_fetch_sub(&self->_queued,1);self.outputCompletedBuffers++;}];}
   }
  }
  next+=.01;double wait=next-NSProcessInfo.processInfo.systemUptime;if(wait>0)[NSThread sleepForTimeInterval:wait];else if(wait<-.1)next=NSProcessInfo.processInfo.systemUptime;
 }
 self.delegate=nil;
 }
}
@end

@interface ExternalCapturePlugin()
@property(nonatomic,strong) ExternalAudioDevice *audio;
@property(nonatomic,strong) RTCVideoSource *source;
@property(nonatomic,strong) RTCVideoCapturer *capturer;
@property(nonatomic,strong) RTCMediaStream *stream;
@property(nonatomic) NSUInteger videoFrames;
@end
@implementation ExternalCapturePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
 FlutterMethodChannel *channel=[FlutterMethodChannel methodChannelWithName:@"external_capture" binaryMessenger:registrar.messenger];
 ExternalCapturePlugin *instance=[ExternalCapturePlugin new];[registrar addMethodCallDelegate:instance channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
 NSDictionary *a=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:@{};
 FlutterWebRTCPlugin *p=[FlutterWebRTCPlugin sharedSingleton];
 if([call.method isEqual:@"prepare"]) {
  if(p.peerConnectionFactory){result([FlutterError errorWithCode:@"factory_already_initialized" message:@"Call prepare before the first flutter_webrtc operation" details:nil]);return;}
  self.audio=[ExternalAudioDevice new];
  [FlutterWebRTCPlugin setAudioSessionManagementEnabled:NO];
  p.peerConnectionFactory=[[RTCPeerConnectionFactory alloc]initWithEncoderFactory:[RTCDefaultVideoEncoderFactory new] decoderFactory:[RTCDefaultVideoDecoderFactory new] audioDevice:self.audio];
  result(nil);
 }else if([call.method isEqual:@"create"]) {
  if(self.stream){result([FlutterError errorWithCode:@"already_created" message:@"Only one external stream per run" details:nil]);return;}
  RTCPeerConnectionFactory *f=p.peerConnectionFactory;
  if(!self.audio||!f){result([FlutterError errorWithCode:@"not_prepared" message:@"prepare required" details:nil]);return;}
  self.source=[f videoSource]; self.capturer=[[RTCVideoCapturer alloc]initWithDelegate:self.source];
  RTCVideoTrack *video=[f videoTrackWithSource:self.source trackId:@"external-video"];
  RTCMediaConstraints *constraints=[[RTCMediaConstraints alloc]initWithMandatoryConstraints:@{@"googEchoCancellation":@"false",@"googNoiseSuppression":@"false",@"googAutoGainControl":@"false"} optionalConstraints:nil];
  RTCAudioTrack *audio=[f audioTrackWithSource:[f audioSourceWithConstraints:constraints] trackId:@"external-audio"];
  self.stream=[f mediaStreamWithStreamId:@"external-stream"];[self.stream addVideoTrack:video];[self.stream addAudioTrack:audio];
  p.localStreams[self.stream.streamId]=self.stream;
  p.localTracks[video.trackId]=[[LocalVideoTrack alloc]initWithTrack:video];p.localTracks[audio.trackId]=[[LocalAudioTrack alloc]initWithTrack:audio];
  result(@{@"streamId":self.stream.streamId,@"audioTrackId":audio.trackId,@"videoTrackId":video.trackId});
 }else if([call.method isEqual:@"pushAudio"]) {
  FlutterStandardTypedData *data=a[@"bytes"];if(!data||data.data.length%2){result([FlutterError errorWithCode:@"bad_audio" message:@"PCM16 requires even bytes" details:nil]);return;}[self.audio enqueue:data.data];result(nil);
 }else if([call.method isEqual:@"pushVideo"]) {
  int w=[a[@"width"]intValue],h=[a[@"height"]intValue];FlutterStandardTypedData *data=a[@"bytes"];
  if(w<=0||h<=0||data.data.length!=(NSUInteger)w*h*4){result([FlutterError errorWithCode:@"bad_video" message:@"Expected packed BGRA" details:nil]);return;}
  CVPixelBufferRef pixel=NULL;CVReturn code=CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pixel);
  if(code!=kCVReturnSuccess){result([FlutterError errorWithCode:@"pixel_buffer" message:@"Allocation failed" details:nil]);return;}
  CVPixelBufferLockBaseAddress(pixel,0);uint8_t *dst=CVPixelBufferGetBaseAddress(pixel);const uint8_t *src=data.data.bytes;size_t stride=CVPixelBufferGetBytesPerRow(pixel);for(int y=0;y<h;y++)memcpy(dst+y*stride,src+y*w*4,w*4);CVPixelBufferUnlockBaseAddress(pixel,0);
  RTCCVPixelBuffer *buffer=[[RTCCVPixelBuffer alloc]initWithPixelBuffer:pixel];RTCVideoFrame *frame=[[RTCVideoFrame alloc]initWithBuffer:buffer rotation:RTCVideoRotation_0 timeStampNs:[a[@"timestampUs"]longLongValue]*1000];[self.source capturer:self.capturer didCaptureVideoFrame:frame];CVPixelBufferRelease(pixel);self.videoFrames++;result(nil);
 }else if([call.method isEqual:@"stats"]){result(@{@"outputNonzeroSamples":@(self.audio.outputNonzeroSamples),@"outputCompletedBuffers":@(self.audio.outputCompletedBuffers),@"outputEngineRunning":@(self.audio.isPlaying),@"videoFrames":@(self.videoFrames),@"audioReceivedBytes":@(self.audio.receivedBytes),@"audioDroppedBytes":@(self.audio.droppedBytes),@"audioDeliveredBlocks":@(self.audio.deliveredBlocks),@"audioUnderflows":@(self.audio.underflows)});
 }else if([call.method isEqual:@"setOutputEnabled"]){self.audio.outputEnabled=[a[@"enabled"]boolValue];result(nil);
 }else if([call.method isEqual:@"flush"]){[self.audio clear];result(nil);
 }else if([call.method isEqual:@"dispose"]){if(self.stream){[p.localTracks removeObjectForKey:@"external-video"];[p.localTracks removeObjectForKey:@"external-audio"];[p.localStreams removeObjectForKey:self.stream.streamId];}self.stream=nil;self.source=nil;self.capturer=nil;[self.audio clear];result(nil);
 }else result(FlutterMethodNotImplemented);
}
@end
