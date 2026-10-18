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
  NSMutableDictionary<NSNumber*,NSData*> *_scheduled;
  BOOL _scheduledEnabled;
  NSUInteger _scheduledOrigin;
  NSUInteger _scheduledLast;
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
@property(nonatomic) NSUInteger scheduledLateFrames;
@property(nonatomic) NSUInteger scheduledConsumedFrames;
@property(nonatomic) NSUInteger scheduledUnderflows;
@property(nonatomic) BOOL outputEnabled;
@property(nonatomic) NSUInteger outputNonzeroSamples;
@property(nonatomic) NSUInteger outputCompletedBuffers;
- (void)enqueue:(NSData *)data;
- (double)nextInputMs;
- (double)beginScheduled:(NSUInteger)delay;
- (NSUInteger)schedule:(NSData*)data start:(NSUInteger)frame;
- (void)endScheduled;
- (void)clear;
@end
@implementation ExternalAudioDevice
- (instancetype)init { if ((self=[super init])) { _lock=[NSLock new];_pending=[NSMutableData new];_scheduled=[NSMutableDictionary new];atomic_init(&_stop,false);atomic_init(&_recording,false);atomic_init(&_playing,false);atomic_init(&_queued,0);self.outputEnabled=YES; } return self; }
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
- (double)nextInputMs {[_lock lock];double ms=self.deliveredBlocks*10.0+_pending.length/96.0;[_lock unlock];return ms;}
- (double)beginScheduled:(NSUInteger)delay {[_lock lock];[_scheduled removeAllObjects];[_pending setLength:0];_scheduledEnabled=YES;_scheduledOrigin=self.deliveredBlocks+(delay+9)/10;_scheduledLast=_scheduledOrigin;double ms=_scheduledOrigin*10.0;[_lock unlock];return ms;}
- (void)endScheduled {[_lock lock];_scheduledEnabled=NO;[_scheduled removeAllObjects];[_lock unlock];}
- (NSUInteger)schedule:(NSData*)data start:(NSUInteger)frame {[_lock lock];NSUInteger late=0;self.receivedBytes+=data.length;for(NSUInteger i=0;i<data.length/960;i++){NSUInteger n=_scheduledOrigin+frame+i;if(n<self.deliveredBlocks){self.scheduledLateFrames++;self.droppedBytes+=960;late++;continue;}if(_scheduled.count>=400){self.droppedBytes+=960;continue;}_scheduled[@(n)]=[data subdataWithRange:NSMakeRange(i*960,960)];_scheduledLast=MAX(_scheduledLast,n+1);}[_lock unlock];return late;}
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
    [_lock lock];if(_scheduledEnabled){NSData *block=_scheduled[@(self.deliveredBlocks)];if(block){memcpy(pcm,block.bytes,960);[_scheduled removeObjectForKey:@(self.deliveredBlocks)];self.scheduledConsumedFrames++;}else if(self.deliveredBlocks>=_scheduledOrigin&&self.deliveredBlocks<_scheduledLast){self.scheduledUnderflows++;}}else if(_pending.length>=sizeof(pcm)){memcpy(pcm,_pending.bytes,sizeof(pcm));[_pending replaceBytesInRange:NSMakeRange(0,sizeof(pcm)) withBytes:NULL length:0];}else{self.underflows++;}self.deliveredBlocks++;[_lock unlock];
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=sizeof(pcm),.mData=pcm}}};
    self.delegate.deliverRecordedData(&flags,&stamp,0,480,&list,NULL,nil);
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
 }else if([call.method isEqual:@"beginScheduled"]){result(@{@"device_origin_ms":@([self.audio beginScheduled:[a[@"delay_ms"]unsignedIntegerValue]])});
 }else if([call.method isEqual:@"endScheduled"]){[self.audio endScheduled];result(nil);
 }else if([call.method isEqual:@"scheduleAudio"]){FlutterStandardTypedData *data=a[@"bytes"];if(data.data.length%960){result([FlutterError errorWithCode:@"bad_scheduled_pcm" message:@"Expected 10ms PCM blocks" details:nil]);return;}result(@{@"late_prefix_frames":@([self.audio schedule:data.data start:[a[@"start_frame"]unsignedIntegerValue]])});
 }else if([call.method isEqual:@"pushAudioTimed"]) {
  FlutterStandardTypedData *data=a[@"bytes"];double ms=[self.audio nextInputMs];[self.audio enqueue:data.data];result(@{@"device_start_ms":@(ms)});
 }else if([call.method isEqual:@"pushAudio"]) {
  FlutterStandardTypedData *data=a[@"bytes"];if(!data||data.data.length%2){result([FlutterError errorWithCode:@"bad_audio" message:@"PCM16 requires even bytes" details:nil]);return;}[self.audio enqueue:data.data];result(nil);
 }else if([call.method isEqual:@"pushVideo"]) {
  int w=[a[@"width"]intValue],h=[a[@"height"]intValue];FlutterStandardTypedData *data=a[@"bytes"];
  if(w<=0||h<=0||data.data.length!=(NSUInteger)w*h*4){result([FlutterError errorWithCode:@"bad_video" message:@"Expected packed BGRA" details:nil]);return;}
  CVPixelBufferRef pixel=NULL;CVReturn code=CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pixel);
  if(code!=kCVReturnSuccess){result([FlutterError errorWithCode:@"pixel_buffer" message:@"Allocation failed" details:nil]);return;}
  CVPixelBufferLockBaseAddress(pixel,0);uint8_t *dst=CVPixelBufferGetBaseAddress(pixel);const uint8_t *src=data.data.bytes;size_t stride=CVPixelBufferGetBytesPerRow(pixel);for(int y=0;y<h;y++)memcpy(dst+y*stride,src+y*w*4,w*4);CVPixelBufferUnlockBaseAddress(pixel,0);
  RTCCVPixelBuffer *buffer=[[RTCCVPixelBuffer alloc]initWithPixelBuffer:pixel];RTCVideoFrame *frame=[[RTCVideoFrame alloc]initWithBuffer:buffer rotation:RTCVideoRotation_0 timeStampNs:[a[@"timestampUs"]longLongValue]*1000];[self.source capturer:self.capturer didCaptureVideoFrame:frame];CVPixelBufferRelease(pixel);self.videoFrames++;result(nil);
 }else if([call.method isEqual:@"stats"]){result(@{@"scheduledLateFrames":@(self.audio.scheduledLateFrames),@"scheduledConsumedFrames":@(self.audio.scheduledConsumedFrames),@"scheduledUnderflows":@(self.audio.scheduledUnderflows),@"outputNonzeroSamples":@(self.audio.outputNonzeroSamples),@"outputCompletedBuffers":@(self.audio.outputCompletedBuffers),@"outputEngineRunning":@(self.audio.isPlaying),@"videoFrames":@(self.videoFrames),@"audioReceivedBytes":@(self.audio.receivedBytes),@"audioDroppedBytes":@(self.audio.droppedBytes),@"audioDeliveredBlocks":@(self.audio.deliveredBlocks),@"audioUnderflows":@(self.audio.underflows)});
 }else if([call.method isEqual:@"setOutputEnabled"]){self.audio.outputEnabled=[a[@"enabled"]boolValue];result(nil);
 }else if([call.method isEqual:@"flush"]){[self.audio clear];result(nil);
 }else if([call.method isEqual:@"dispose"]){if(self.stream){[p.localTracks removeObjectForKey:@"external-video"];[p.localTracks removeObjectForKey:@"external-audio"];[p.localStreams removeObjectForKey:self.stream.streamId];}self.stream=nil;self.source=nil;self.capturer=nil;[self.audio clear];result(nil);
 }else result(FlutterMethodNotImplemented);
}
@end
