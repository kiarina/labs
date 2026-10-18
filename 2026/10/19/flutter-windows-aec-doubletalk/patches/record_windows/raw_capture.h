#pragma once
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
namespace record_windows {
inline std::atomic<uint64_t> raw_audit[7]{};
// Indices: requests, RAW properties accepted, starts, native frames, last HRESULT.
class RawCapture {
 public:
 using Chunk=std::function<void(std::vector<uint8_t>)>;
 ~RawCapture(){Stop();}
 HRESULT Start(std::wstring endpoint,Chunk chunk){
  Stop();quit_=false;ready_=false;raw_audit[0]++;
  worker_=std::thread([this,endpoint,chunk]{Run(endpoint,chunk);});
  std::unique_lock<std::mutex> lock(mutex_);cv_.wait(lock,[this]{return ready_;});
  const auto hr=status_;lock.unlock();if(FAILED(hr))Stop();return hr;
 }
 void Stop(){quit_=true;if(worker_.joinable())worker_.join();}
 private:
 void Ready(HRESULT hr){raw_audit[4]=static_cast<uint32_t>(hr);{std::lock_guard<std::mutex> l(mutex_);status_=hr;ready_=true;}cv_.notify_one();}
 void Run(const std::wstring& endpoint,const Chunk& chunk){
  HRESULT hr=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
  if(FAILED(hr)){Ready(hr);return;}
  { // Release every COM object before CoUninitialize.
   using Microsoft::WRL::ComPtr;
   ComPtr<IMMDeviceEnumerator> enumerator;ComPtr<IMMDevice> device;
   ComPtr<IAudioClient2> client;ComPtr<IAudioCaptureClient> capture;
   WAVEFORMATEX* format=nullptr;
   hr=CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&enumerator));
   if(SUCCEEDED(hr))hr=enumerator->GetDevice(endpoint.c_str(),&device);
   if(SUCCEEDED(hr))hr=device->Activate(__uuidof(IAudioClient2),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(client.GetAddressOf()));
   AudioClientProperties props{};props.cbSize=sizeof(props);props.eCategory=AudioCategory_Other;props.Options=AUDCLNT_STREAMOPTIONS_RAW;
   if(SUCCEEDED(hr))hr=client->SetClientProperties(&props);
   if(SUCCEEDED(hr)){raw_audit[1]++;hr=client->GetMixFormat(&format);}
   bool floating=false;unsigned channels=0,bits=0,rate=0;
   if(SUCCEEDED(hr)){
    channels=format->nChannels;bits=format->wBitsPerSample;rate=format->nSamplesPerSec;
    auto tag=format->wFormatTag;
    if(tag==WAVE_FORMAT_EXTENSIBLE){auto ext=reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format);floating=IsEqualGUID(ext->SubFormat,KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);if(!floating&&!IsEqualGUID(ext->SubFormat,KSDATAFORMAT_SUBTYPE_PCM))hr=AUDCLNT_E_UNSUPPORTED_FORMAT;}
    else if(tag==WAVE_FORMAT_IEEE_FLOAT)floating=true;else if(tag!=WAVE_FORMAT_PCM)hr=AUDCLNT_E_UNSUPPORTED_FORMAT;
    if(channels<1||channels>16||rate<8000||rate>192000||(floating?bits!=32:(bits!=16&&bits!=24&&bits!=32)))hr=AUDCLNT_E_UNSUPPORTED_FORMAT;
   }
   if(SUCCEEDED(hr))hr=client->Initialize(AUDCLNT_SHAREMODE_SHARED,0,200000,0,format,nullptr);
   if(SUCCEEDED(hr))hr=client->GetService(IID_PPV_ARGS(&capture));
   if(SUCCEEDED(hr))hr=client->Start();
   if(SUCCEEDED(hr)){raw_audit[2]++;raw_audit[6]++;}
   Ready(hr);
   double position=0;uint64_t source_index=0;double previous=0;
   std::vector<uint8_t> output;output.reserve(960);
   while(SUCCEEDED(hr)&&!quit_){
    UINT32 available=0;hr=capture->GetNextPacketSize(&available);
    if(FAILED(hr))break;
    if(!available){Sleep(2);continue;}
    BYTE* data=nullptr;DWORD flags=0;UINT32 frames=0;
    hr=capture->GetBuffer(&data,&frames,&flags,nullptr,nullptr);
    if(FAILED(hr))break;
    raw_audit[3]+=frames;
    for(UINT32 i=0;i<frames;i++,source_index++){
     double value=0;
     if(!(flags&AUDCLNT_BUFFERFLAGS_SILENT))for(unsigned c=0;c<channels;c++){
      const BYTE* p=data+i*format->nBlockAlign+c*(bits/8);
      if(floating){float v;memcpy(&v,p,4);if(std::isfinite(v))value+=v;}
      else if(bits==16){int16_t v;memcpy(&v,p,2);value+=v/32768.;}
      else if(bits==24){int32_t v=static_cast<int32_t>((uint32_t(p[2])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[0])<<8));value+=v/2147483648.;}
      else {int32_t v;memcpy(&v,p,4);value+=v/2147483648.;}
     }
     value/=channels;
     while(position<=static_cast<double>(source_index)){
      double v=source_index?previous+(value-previous)*(position-(static_cast<double>(source_index)-1)):value;
      v= v>1?1:(v< -1?-1:v);int16_t pcm=static_cast<int16_t>(std::lround(v*32767));
      output.push_back(static_cast<uint8_t>(pcm));output.push_back(static_cast<uint8_t>(static_cast<uint16_t>(pcm)>>8));
      if(output.size()==960){chunk(std::move(output));output.clear();output.reserve(960);}
      position+=static_cast<double>(rate)/48000.;
     }
     previous=value;
    }
    HRESULT release=capture->ReleaseBuffer(frames);if(FAILED(release))hr=release;
   }
   raw_audit[4]=static_cast<uint32_t>(hr);
   if(client)client->Stop();if(SUCCEEDED(status_))raw_audit[6]--;if(format)CoTaskMemFree(format);
  }
  CoUninitialize();
 }
 std::thread worker_;std::atomic<bool> quit_{false};std::mutex mutex_;std::condition_variable cv_;bool ready_=false;HRESULT status_=E_PENDING;
};
}
