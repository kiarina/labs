#include <jni.h>
#include <cstdint>
#include <vector>
#include <mutex>
#include "aec_engine.h"

namespace {
struct State {
  void* aec;
  std::mutex mutex;
  std::vector<int16_t> capture_pending, reverse_pending;
};
State* state(jlong handle) { return reinterpret_cast<State*>(handle); }
std::vector<int16_t> read(JNIEnv* env,jbyteArray bytes) {
  jsize length=env->GetArrayLength(bytes);
  std::vector<jbyte> data(length);env->GetByteArrayRegion(bytes,0,length,data.data());
  std::vector<int16_t> result(length/2);
  for(size_t i=0;i<result.size();++i)
    result[i]=static_cast<int16_t>(static_cast<uint8_t>(data[i*2])|
        (static_cast<uint16_t>(static_cast<uint8_t>(data[i*2+1]))<<8));
  return result;
}
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_kiarina_labs_aec_1audio_AecAudioPlugin_create(JNIEnv*,jobject,jboolean enabled) {
  auto* s=new State;s->aec=aec_create(enabled?1:0);
  if(!s->aec){delete s;return 0;}return reinterpret_cast<jlong>(s);
}
extern "C" JNIEXPORT void JNICALL
Java_com_kiarina_labs_aec_1audio_AecAudioPlugin_destroy(JNIEnv*,jobject,jlong handle) {
  auto* s=state(handle);if(!s)return;aec_destroy(s->aec);delete s;
}
extern "C" JNIEXPORT void JNICALL
Java_com_kiarina_labs_aec_1audio_AecAudioPlugin_reverse(JNIEnv* env,jobject,jlong handle,jbyteArray bytes) {
  auto* s=state(handle);auto input=read(env,bytes);std::lock_guard<std::mutex> lock(s->mutex);
  s->reverse_pending.insert(s->reverse_pending.end(),input.begin(),input.end());
  size_t used=0;
  while(s->reverse_pending.size()-used>=480){if(aec_reverse(s->aec,s->reverse_pending.data()+used,480)!=0){env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"AEC reverse failed");return;}used+=480;}
  s->reverse_pending.erase(s->reverse_pending.begin(),s->reverse_pending.begin()+used);
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_kiarina_labs_aec_1audio_AecAudioPlugin_capture(JNIEnv* env,jobject,jlong handle,jbyteArray bytes,jint delay) {
  auto* s=state(handle);auto input=read(env,bytes);std::lock_guard<std::mutex> lock(s->mutex);
  s->capture_pending.insert(s->capture_pending.end(),input.begin(),input.end());
  std::vector<int16_t> output((s->capture_pending.size()/480)*480);
  for(size_t used=0;used<output.size();used+=480)
    if(aec_capture(s->aec,s->capture_pending.data()+used,output.data()+used,480,delay)!=0) {
      env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"AEC capture failed");return nullptr;
    }
  s->capture_pending.erase(s->capture_pending.begin(),s->capture_pending.begin()+output.size());
  auto result=env->NewByteArray(static_cast<jsize>(output.size()*2));
  // Android's supported ABIs are little-endian.
  env->SetByteArrayRegion(result,0,static_cast<jsize>(output.size()*2),reinterpret_cast<const jbyte*>(output.data()));
  return result;
}
extern "C" JNIEXPORT void JNICALL
Java_com_kiarina_labs_aec_1audio_AecAudioPlugin_reset(JNIEnv*,jobject,jlong handle) {
  auto* s=state(handle);std::lock_guard<std::mutex> lock(s->mutex);
  s->capture_pending.clear();s->reverse_pending.clear();aec_reset(s->aec);
}
