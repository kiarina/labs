#include "aec_engine.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include "api/echo_canceller3_config.h"
#include "api/echo_canceller3_factory.h"
#include "api/echo_control.h"
#include "api/environment.h"
#include "audio_processing/audio_buffer.h"

// Serialized, device-free DSP. No microphone, playback or PeerConnection lives here.
namespace {
struct Engine {
  bool enabled;
  std::mutex mutex;
  std::unique_ptr<lab_aec_webrtc::EchoControl> echo;
  lab_aec_webrtc::AudioBuffer render{48000,1,48000,1,48000,1};
  lab_aec_webrtc::AudioBuffer capture{48000,1,48000,1,48000,1};
  explicit Engine(bool on):enabled(on){reset();}
  void reset(){
    lab_aec_webrtc::EchoCanceller3Config config;
    lab_aec_webrtc::Environment environment;
    lab_aec_webrtc::EchoCanceller3Factory factory(config);
    echo=factory.Create(environment,48000,1,1);
    echo->SetCaptureOutputUsage(true);
  }
};
}
extern "C" {
void* aec_create(int enabled){try{return new Engine(enabled!=0);}catch(...){return nullptr;}}
int aec_reverse(void* handle,const int16_t* pcm,int samples){
  if(!handle||!pcm||samples!=480)return -1;
  auto& e=*static_cast<Engine*>(handle);std::lock_guard<std::mutex> lock(e.mutex);
  if(!e.enabled)return 0;
  for(int i=0;i<480;i++)e.render.channels()[0][i]=pcm[i];
  e.render.SplitIntoFrequencyBands();
  e.echo->AnalyzeRender(&e.render);return 0;
}
int aec_capture(void* handle,const int16_t* pcm,int16_t* out,int samples,int delay_ms){
  if(!handle||!pcm||!out||samples!=480||delay_ms<0||delay_ms>1000)return -1;
  auto& e=*static_cast<Engine*>(handle);std::lock_guard<std::mutex> lock(e.mutex);
  if(!e.enabled){std::copy(pcm,pcm+480,out);return 0;}
  for(int i=0;i<480;i++)e.capture.channels()[0][i]=pcm[i];
  e.echo->SetAudioBufferDelay(delay_ms);
  e.echo->AnalyzeCapture(&e.capture);
  e.capture.SplitIntoFrequencyBands();
  e.echo->ProcessCapture(&e.capture,false);
  e.capture.MergeFrequencyBands();
  for(int i=0;i<480;i++)out[i]=static_cast<int16_t>(std::clamp(std::lrint(e.capture.channels_const()[0][i]),-32768L,32767L));
  return 0;
}
void aec_reset(void* handle){if(!handle)return;auto& e=*static_cast<Engine*>(handle);std::lock_guard<std::mutex> lock(e.mutex);e.reset();}
void aec_destroy(void* handle){delete static_cast<Engine*>(handle);}
}
