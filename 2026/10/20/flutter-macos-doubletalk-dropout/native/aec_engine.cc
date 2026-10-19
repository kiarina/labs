#include "aec_engine.h"
#include <algorithm>
#include <array>
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
  int preset;
  std::array<float,64> linear_history{};
  int linear_position=0;
  std::mutex mutex;
  std::unique_ptr<lab_aec_webrtc::EchoControl> echo;
  lab_aec_webrtc::AudioBuffer render{48000,1,48000,1,48000,1};
  lab_aec_webrtc::AudioBuffer linear{16000,1,16000,1,16000,1};
  lab_aec_webrtc::AudioBuffer capture{48000,1,48000,1,48000,1};
  explicit Engine(bool on,int choice=0):enabled(on),preset(choice){reset();}
  void reset(){
    linear_history.fill(0);linear_position=0;
    lab_aec_webrtc::EchoCanceller3Config config;
    if(preset==1 || preset==4)config.echo_removal_control.has_clock_drift=true;
    if(preset==2 || preset==4 || preset==6 || (preset>=13 && preset<=15)){
      config.filter.refined.length_blocks=26;
      config.filter.coarse.length_blocks=26;
      config.filter.refined_initial.length_blocks=26;
      config.filter.coarse_initial.length_blocks=26;
    }
    if(preset==3 || preset==7)config.suppressor.nearend_tuning=config.suppressor.normal_tuning;
    if(preset>=5 && preset<=15)config.delay.use_external_delay_estimator=true;
    if(preset==8 || preset==9 || preset==11 || preset==15){
      const float factor=preset==8?2.f:5.f;
      config.suppressor.nearend_tuning.mask_lf.enr_transparent*=factor;
      config.suppressor.nearend_tuning.mask_lf.enr_suppress*=factor;
      config.suppressor.nearend_tuning.mask_hf.enr_transparent*=factor;
      config.suppressor.nearend_tuning.mask_hf.enr_suppress*=factor;
    }
    if(preset>=10 && preset<=15)config.filter.enable_coarse_filter_output_usage=false;
    if(preset==12 || preset==13)config.filter.export_linear_aec_output=true;
    if(preset==16 || preset==17){
      config.suppressor.dominant_nearend_detection.snr_threshold=3.f;
      config.suppressor.dominant_nearend_detection.trigger_threshold=3;
    }
    if(preset==17){
      config.suppressor.nearend_tuning.mask_lf.enr_transparent*=5.f;
      config.suppressor.nearend_tuning.mask_lf.enr_suppress*=5.f;
      config.suppressor.nearend_tuning.mask_hf.enr_transparent*=5.f;
      config.suppressor.nearend_tuning.mask_hf.enr_suppress*=5.f;
    }
    lab_aec_webrtc::EchoCanceller3Config::Validate(&config);
    lab_aec_webrtc::Environment environment;
    lab_aec_webrtc::EchoCanceller3Factory factory(config);
    echo=factory.Create(environment,48000,1,1);
    echo->SetCaptureOutputUsage(true);
  }
};
}
extern "C" {
void* aec_create(int enabled){try{return new Engine(enabled!=0);}catch(...){return nullptr;}}
void* aec_create_config(int enabled,int preset){if(preset<0||preset>20)return nullptr;try{return new Engine(enabled!=0,preset);}catch(...){return nullptr;}}
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
  for(int i=0;i<480;i++)e.capture.channels()[0][i]=pcm[i]*(e.preset==18?8.f:e.preset==19?2.f:e.preset==20?4.f:1.f);
  e.echo->SetAudioBufferDelay(delay_ms);
  e.echo->AnalyzeCapture(&e.capture);
  e.capture.SplitIntoFrequencyBands();
  if(e.preset==12 || e.preset==13){
    e.echo->ProcessCapture(&e.capture,&e.linear,false);
    // Linear export precedes the residual suppressor's 64-sample block delay.
    // Align low-band linear output with the other synthesized bands.
    for(int i=0;i<160;++i){
      const float sample=e.linear.channels()[0][i];
      e.capture.split_bands(0)[0][i]=e.linear_history[e.linear_position];
      e.linear_history[e.linear_position]=sample;e.linear_position=(e.linear_position+1)%64;
    }
  }else e.echo->ProcessCapture(&e.capture,false);
  e.capture.MergeFrequencyBands();
  for(int i=0;i<480;i++)out[i]=static_cast<int16_t>(std::clamp(std::lrint(e.capture.channels_const()[0][i]/(e.preset==18?8.f:e.preset==19?2.f:e.preset==20?4.f:1.f)),-32768L,32767L));
  return 0;
}
void aec_reset(void* handle){if(!handle)return;auto& e=*static_cast<Engine*>(handle);std::lock_guard<std::mutex> lock(e.mutex);e.reset();}
void aec_destroy(void* handle){delete static_cast<Engine*>(handle);}
}
