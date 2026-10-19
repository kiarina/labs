#include "aec_audio_plugin.h"
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <array>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <future>
#include <mutex>
#include <thread>
#include <vector>
#include "aec_engine.h"
using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;
namespace aec_audio {
namespace {
EncodableValue Count(uint64_t n){return EncodableValue(static_cast<int64_t>(n));}
const EncodableValue* Arg(const EncodableMap& a,const char* key){auto i=a.find(EncodableValue(key));return i==a.end()?nullptr:&i->second;}
int Number(const EncodableMap& a,const char* key,int fallback){auto v=Arg(a,key);return v&&std::holds_alternative<int32_t>(*v)?std::get<int32_t>(*v):fallback;}
std::vector<uint8_t> Bytes(const std::vector<int16_t>& p){std::vector<uint8_t>b(p.size()*2);for(size_t i=0;i<p.size();++i){b[i*2]=p[i]&255;b[i*2+1]=(static_cast<uint16_t>(p[i])>>8)&255;}return b;}
}
class State {
 public:
  std::array<void*,4> engines{};
  const std::array<const char*,4> names{"baseline","clockDrift","conditioned","headroom"};
  std::atomic<bool> stop{false};
  std::thread thread;
  std::atomic<uint64_t> reverse_blocks{0},capture_samples{0},dsp_errors{0},discontinuities{0},silent_packets{0};
  std::atomic<int64_t> hresult{0};
  uint32_t rate=0,channels=0;
  int delay_ms=20;
  std::vector<int16_t> pending,trace;
  std::mutex trace_mutex,dsp_mutex;
  std::vector<uint8_t> events;
  uint64_t conditioned_overrange=0;
  ~State(){Dispose();}
  void Dispose(){stop=true;if(thread.joinable())thread.join();for(auto& e:engines){if(e)aec_destroy(e);e=nullptr;}pending.clear();}
  HRESULT Configure(const std::string& endpoint,int delay){
    Dispose();stop=false;hresult=0;reverse_blocks=0;capture_samples=0;dsp_errors=0;discontinuities=0;silent_packets=0;trace.clear();events.clear();conditioned_overrange=0;delay_ms=delay;
    engines[0]=aec_create_config(1,0);
    if(!engines[0])return E_FAIL;
    auto ready=std::make_shared<std::promise<HRESULT>>();auto future=ready->get_future();
    thread=std::thread([this,endpoint,ready]{Loop(endpoint,ready);});
    return future.get();
  }
  void Loop(const std::string& endpoint,std::shared_ptr<std::promise<HRESULT>> ready){
    HRESULT hr=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if(FAILED(hr)){hresult=hr;ready->set_value(hr);return;}
    bool signalled=false;
    auto run=[&]()->HRESULT{
      ComPtr<IMMDeviceEnumerator> enumerator;ComPtr<IMMDevice> device;ComPtr<IAudioClient> client;ComPtr<IAudioCaptureClient> capture;
      HRESULT r=CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&enumerator));if(FAILED(r))return r;
      int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,endpoint.data(),static_cast<int>(endpoint.size()),nullptr,0);if(n<=0)return E_INVALIDARG;
      std::wstring id(n,L'\0');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,endpoint.data(),static_cast<int>(endpoint.size()),id.data(),n);
      r=enumerator->GetDevice(id.c_str(),&device);if(FAILED(r))return r;
      r=device->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(client.GetAddressOf()));if(FAILED(r))return r;
      WAVEFORMATEX* format=nullptr;r=client->GetMixFormat(&format);if(FAILED(r))return r;
      rate=format->nSamplesPerSec;channels=format->nChannels;
      const bool floating=format->wFormatTag==WAVE_FORMAT_IEEE_FLOAT || (format->wFormatTag==WAVE_FORMAT_EXTENSIBLE && reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->SubFormat.Data1==WAVE_FORMAT_IEEE_FLOAT);
      if(!floating || format->wBitsPerSample!=32 || (rate!=48000&&rate!=96000) || channels<1 || channels>8){CoTaskMemFree(format);return E_NOTIMPL;}
      r=client->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_LOOPBACK,10000000,0,format,nullptr);CoTaskMemFree(format);if(FAILED(r))return r;
      r=client->GetService(IID_PPV_ARGS(&capture));if(FAILED(r))return r;
      r=client->Start();if(FAILED(r))return r;
      signalled=true;ready->set_value(S_OK);
      std::vector<int16_t> block;block.reserve(480);double accumulated=0;int count=0;
      while(!stop){
        UINT32 packet=0;r=capture->GetNextPacketSize(&packet);if(FAILED(r))break;
        while(packet){
          BYTE* data=nullptr;UINT32 frames=0;DWORD flags=0;UINT64 position=0,qpc=0;
          r=capture->GetBuffer(&data,&frames,&flags,&position,&qpc);if(FAILED(r))break;
          if(flags&AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)++discontinuities;
          if(flags&AUDCLNT_BUFFERFLAGS_SILENT)++silent_packets;
          for(UINT32 f=0;f<frames;++f){
            double mono=0;
            if(!(flags&AUDCLNT_BUFFERFLAGS_SILENT))for(uint32_t ch=0;ch<channels;++ch)mono+=reinterpret_cast<float*>(data)[static_cast<size_t>(f)*channels+ch]/channels;
            accumulated+=mono;
            if(++count==static_cast<int>(rate/48000)){
              block.push_back(static_cast<int16_t>(std::clamp(std::lrint(accumulated/count*32768),-32768L,32767L)));count=0;accumulated=0;
              if(block.size()==480){
                {std::lock_guard<std::mutex> dsp_lock(dsp_mutex);
                for(auto e:engines)if(aec_reverse(e,block.data(),480)!=0)++dsp_errors;events.push_back(1);}
                {std::lock_guard<std::mutex> lock(trace_mutex);if(trace.size()+480<=48000*180)trace.insert(trace.end(),block.begin(),block.end());else ++dsp_errors;}
                ++reverse_blocks;block.clear();
              }
            }
          }
          capture->ReleaseBuffer(frames);r=capture->GetNextPacketSize(&packet);if(FAILED(r))break;
        }
        if(FAILED(r))break;Sleep(2);
      }
      client->Stop();return r;
    };
    hr=run();hresult=hr;if(!signalled)ready->set_value(hr);CoUninitialize();
  }
  EncodableMap Stats(){
    EncodableMap m{{EncodableValue("reverseBlocks"),Count(reverse_blocks)},{EncodableValue("captureSamples"),Count(capture_samples)},{EncodableValue("dspErrors"),Count(dsp_errors)},{EncodableValue("loopbackHresult"),EncodableValue(hresult.load())},{EncodableValue("discontinuities"),Count(discontinuities)},{EncodableValue("silentPackets"),Count(silent_packets)},{EncodableValue("renderRate"),Count(rate)},{EncodableValue("renderChannels"),Count(channels)},{EncodableValue("referenceKind"),EncodableValue("selected render endpoint LOOPBACK; no microphone or speaker owner")}};
    m[EncodableValue("conditionedGain")]=EncodableValue(8);m[EncodableValue("conditionedOverrangeSamples")]=Count(conditioned_overrange);
    m[EncodableValue("headroomCaptureGain")]=EncodableValue(.5);m[EncodableValue("headroomPostGain")]=EncodableValue(1);
    using Audit=uint64_t(__cdecl*)(int);auto module=GetModuleHandleW(L"record_windows_plugin.dll");auto audit=module?reinterpret_cast<Audit>(GetProcAddress(module,"RecordRawAudit")):nullptr;
    if(audit){const char* keys[]={"rawRequests","rawPropertiesAccepted","rawStarts","nativeCaptureFrames","lastHresult","mfCreateRequests","activeRawCaptures"};EncodableMap a;for(int i=0;i<7;++i)a[EncodableValue(keys[i])]=Count(audit(i));m[EncodableValue("recordRawAudit")]=EncodableValue(a);}else m[EncodableValue("recordRawAuditMissing")]=EncodableValue(true);
    return m;
  }
};
AecAudioPlugin::AecAudioPlugin():state_(std::make_unique<State>()){}
AecAudioPlugin::~AecAudioPlugin()=default;
void AecAudioPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar){
 auto channel=std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(),"aec_audio",&flutter::StandardMethodCodec::GetInstance());
 auto plugin=std::make_unique<AecAudioPlugin>();channel->SetMethodCallHandler([p=plugin.get()](const auto& c,auto r){p->Handle(c,std::move(r));});registrar->AddPlugin(std::move(plugin));
}
void AecAudioPlugin::Handle(const flutter::MethodCall<EncodableValue>& call,std::unique_ptr<flutter::MethodResult<EncodableValue>> result){
 auto& s=*state_;const EncodableMap empty;auto args=call.arguments()?std::get_if<EncodableMap>(call.arguments()):nullptr;const auto& a=args?*args:empty;
 if(call.method_name()=="configure"){
  auto id=Arg(a,"deviceId");if(!id||!std::holds_alternative<std::string>(*id)){result->Error("aec","selected render device ID required");return;}
  HRESULT hr=s.Configure(std::get<std::string>(*id),Number(a,"delayMs",20));if(FAILED(hr)){result->Error("aec","render-loopback initialization failed",EncodableValue(static_cast<int64_t>(hr)));return;}result->Success(EncodableValue(s.Stats()));return;
 }
 if(call.method_name()=="captureCompare"){
  auto value=Arg(a,"bytes");if(!value||!std::holds_alternative<std::vector<uint8_t>>(*value)||!s.engines[0]){result->Error("aec","not configured or missing PCM");return;}
  const auto& b=std::get<std::vector<uint8_t>>(*value);for(size_t i=0;i+1<b.size();i+=2)s.pending.push_back(static_cast<int16_t>(b[i]|(b[i+1]<<8)));
  std::array<std::vector<int16_t>,4> output;size_t offset=0;
  std::lock_guard<std::mutex> dsp_lock(s.dsp_mutex);
  while(s.pending.size()-offset>=480){for(int k=0;k<480;++k)if(std::abs(static_cast<int>(s.pending[offset+k]))>4095)++s.conditioned_overrange;for(size_t j=0;j<4;++j){if(!s.engines[j])continue;int16_t block[480];int16_t half[480];if(j==3)for(int k=0;k<480;++k)half[k]=static_cast<int16_t>(std::lrint(s.pending[offset+k]*.5));if(aec_capture(s.engines[j],j==3?half:s.pending.data()+offset,block,480,s.delay_ms)!=0)++s.dsp_errors;output[j].insert(output[j].end(),block,block+480);}s.events.push_back(2);offset+=480;s.capture_samples+=480;}
  s.pending.erase(s.pending.begin(),s.pending.begin()+offset);EncodableMap m;for(size_t j=0;j<4;++j)m[EncodableValue(s.names[j])]=EncodableValue(Bytes(output[j]));result->Success(EncodableValue(m));return;
 }
 if(call.method_name()=="stats"){result->Success(EncodableValue(s.Stats()));return;}
 if(call.method_name()=="freeze"){s.stop=true;if(s.thread.joinable())s.thread.join();result->Success();return;}
 if(call.method_name()=="dspEvents"){std::lock_guard<std::mutex> lock(s.dsp_mutex);result->Success(EncodableValue(s.events));return;}
 if(call.method_name()=="renderTrace"){std::lock_guard<std::mutex> lock(s.trace_mutex);result->Success(EncodableValue(Bytes(s.trace)));return;}
 if(call.method_name()=="dispose"){s.Dispose();result->Success(EncodableValue(s.Stats()));return;}
 result->NotImplemented();
}
}
