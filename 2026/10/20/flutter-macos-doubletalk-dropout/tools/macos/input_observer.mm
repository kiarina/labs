#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <mutex>
#include <cstdio>
static std::mutex outputLock;
static void emit(const char* kind,const void* object,long value,long scope,long bus,long status){
 std::lock_guard<std::mutex> lock(outputLock);
 fprintf(stderr,"INPUT_OBSERVER {\"kind\":\"%s\",\"object\":\"%p\",\"value\":%ld,\"scope\":%ld,\"bus\":%ld,\"status\":%ld}\n",kind,object,value,scope,bus,status);
 void* frames[16];int count=backtrace(frames,16);char** symbols=backtrace_symbols(frames,count);
 if(symbols){for(int i=1;i<count;++i)fprintf(stderr,"INPUT_OBSERVER_STACK %s\n",symbols[i]);free(symbols);}fflush(stderr);
}
static OSStatus observedSet(AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement bus,const void* data,UInt32 size){
 OSStatus result=AudioUnitSetProperty(unit,property,scope,bus,data,size);
 if(property==kAudioOutputUnitProperty_EnableIO && size>=4)emit("enableIO",unit,*(const UInt32*)data,scope,bus,result);
 return result;
}
static OSStatus observedStart(AudioUnit unit){OSStatus result=AudioOutputUnitStart(unit);emit("audioUnitStart",unit,0,0,0,result);return result;}
static OSStatus observedDeviceStart(AudioDeviceID device,AudioDeviceIOProcID proc){OSStatus result=AudioDeviceStart(device,proc);emit("audioDeviceStart",(const void*)proc,device,0,0,result);return result;}
static OSStatus observedDeviceStop(AudioDeviceID device,AudioDeviceIOProcID proc){OSStatus result=AudioDeviceStop(device,proc);emit("audioDeviceStop",(const void*)proc,device,0,0,result);return result;}
#define INTERPOSE(newfn,oldfn) __attribute__((used)) static struct {const void* replacement;const void* replacee;} interpose_##oldfn __attribute__((section("__DATA,__interpose")))={(const void*)&newfn,(const void*)&oldfn};
INTERPOSE(observedSet,AudioUnitSetProperty)
INTERPOSE(observedStart,AudioOutputUnitStart)
INTERPOSE(observedDeviceStart,AudioDeviceStart)
INTERPOSE(observedDeviceStop,AudioDeviceStop)
__attribute__((constructor))static void install(){
 @autoreleasepool {
  Method m=class_getInstanceMethod(AVAudioEngine.class,@selector(inputNode));IMP original=method_getImplementation(m);
  method_setImplementation(m,imp_implementationWithBlock(^id(AVAudioEngine* self){emit("AVAudioEngine.inputNode",(__bridge const void*)self,0,0,0,0);return ((id(*)(id,SEL))original)(self,@selector(inputNode));}));
  emit("installed",nullptr,1,0,0,0);
 }
}
