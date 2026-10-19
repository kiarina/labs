#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <cstdio>
#include <initializer_list>
using Microsoft::WRL::ComPtr;
void PrintFormat(const WAVEFORMATEX* f) {
  if (!f) { std::printf("null"); return; }
  std::printf("{\"tag\":%u,\"channels\":%u,\"rate\":%lu,\"bits\":%u,\"extra\":%u",f->wFormatTag,f->nChannels,f->nSamplesPerSec,f->wBitsPerSample,f->cbSize);
  if(f->wFormatTag==WAVE_FORMAT_EXTENSIBLE && f->cbSize>=22){
    auto* x=reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
    std::printf(",\"validBits\":%u,\"mask\":%lu,\"subformat\":%lu",x->Samples.wValidBitsPerSample,x->dwChannelMask,x->SubFormat.Data1);
  }
  std::printf("}");
}
HRESULT Client(IMMDevice* d,ComPtr<IAudioClient>& c){return d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(c.GetAddressOf()));}
void Check(IMMDevice* device,int role,const char* label,WAVEFORMATEX* fmt,DWORD flags){
  ComPtr<IAudioClient> client; HRESULT activate=Client(device,client);
  WAVEFORMATEX* closest=nullptr;
  HRESULT supported=SUCCEEDED(activate)?client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,fmt,&closest):activate;
  HRESULT init=SUCCEEDED(activate)?client->Initialize(AUDCLNT_SHAREMODE_SHARED,flags,0,0,fmt,nullptr):activate;
  std::printf("{\"role\":%d,\"case\":\"%s\",\"flags\":%lu,\"isSupported\":\"0x%08lx\",\"initialize\":\"0x%08lx\",\"format\":",role,label,flags,static_cast<ULONG>(supported),static_cast<ULONG>(init));
  PrintFormat(fmt); std::printf(",\"closest\":");PrintFormat(closest);std::printf("}\n");
  CoTaskMemFree(closest);
}
int main(){
  HRESULT hr=CoInitializeEx(nullptr,COINIT_MULTITHREADED);if(FAILED(hr))return 1;
  ComPtr<IMMDeviceEnumerator> e;hr=CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&e));if(FAILED(hr))return 2;
  for(int role:{0,2}){
    ComPtr<IMMDevice>d;hr=e->GetDefaultAudioEndpoint(eRender,static_cast<ERole>(role),&d);if(FAILED(hr))return 3;
    ComPtr<IAudioClient> c;Client(d.Get(),c);WAVEFORMATEX* mix=nullptr;hr=c->GetMixFormat(&mix);if(FAILED(hr))return 4;
    Check(d.Get(),role,"mix",mix,0);
    for(int rate:{48000,44100,96000,192000})for(int channels:{1,2}){
      WAVEFORMATEXTENSIBLE x{};auto& f=x.Format;
      f.wFormatTag=WAVE_FORMAT_PCM;f.nChannels=static_cast<WORD>(channels);f.nSamplesPerSec=rate;f.wBitsPerSample=16;f.nBlockAlign=channels*2;f.nAvgBytesPerSec=rate*f.nBlockAlign;
      Check(d.Get(),role,"pcm16-ex",&f,0);
      if(rate==48000){Check(d.Get(),role,"pcm16-autoconvert",&f,AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM|AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY);}
      f.wFormatTag=WAVE_FORMAT_EXTENSIBLE;f.cbSize=22;x.Samples.wValidBitsPerSample=16;x.dwChannelMask=channels==1?SPEAKER_FRONT_CENTER:SPEAKER_FRONT_LEFT|SPEAKER_FRONT_RIGHT;x.SubFormat=KSDATAFORMAT_SUBTYPE_PCM;
      Check(d.Get(),role,"pcm16-extensible",&f,0);
    }
    CoTaskMemFree(mix);
  }
  e.Reset();CoUninitialize();return 0;
}
