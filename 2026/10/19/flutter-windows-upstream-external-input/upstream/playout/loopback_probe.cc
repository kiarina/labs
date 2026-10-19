#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>
#include <wincrypt.h>
#include <cstdio>
#include <cmath>
#include <string>
using Microsoft::WRL::ComPtr;
std::string EndpointHash(IMMDevice* device){
  LPWSTR id=nullptr;device->GetId(&id);int size=WideCharToMultiByte(CP_UTF8,0,id,-1,nullptr,0,nullptr,nullptr);
  std::string text(size,'\0');WideCharToMultiByte(CP_UTF8,0,id,-1,text.data(),size,nullptr,nullptr);CoTaskMemFree(id);text.pop_back();
  HCRYPTPROV provider=0;HCRYPTHASH hash=0;BYTE digest[32]{};DWORD count=32;
  CryptAcquireContext(&provider,nullptr,nullptr,PROV_RSA_AES,CRYPT_VERIFYCONTEXT);CryptCreateHash(provider,CALG_SHA_256,0,0,&hash);CryptHashData(hash,reinterpret_cast<const BYTE*>(text.data()),static_cast<DWORD>(text.size()),0);CryptGetHashParam(hash,HP_HASHVAL,digest,&count,0);CryptDestroyHash(hash);CryptReleaseContext(provider,0);
  std::string output;for(BYTE b:digest){char hex[3];std::sprintf(hex,"%02x",b);output+=hex;}return output;
}
double UtcMs(){FILETIME t;GetSystemTimePreciseAsFileTime(&t);ULARGE_INTEGER n;n.LowPart=t.dwLowDateTime;n.HighPart=t.dwHighDateTime;return (n.QuadPart-116444736000000000ULL)/10000.0;}
int main(int argc,char**argv){
  const double seconds=argc>1?std::atof(argv[1]):45;
  if(FAILED(CoInitializeEx(nullptr,COINIT_MULTITHREADED)))return 1;
  ComPtr<IMMDeviceEnumerator> e;ComPtr<IMMDevice>d;ComPtr<IAudioClient>c;ComPtr<IAudioCaptureClient>capture;
  if(FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&e))))return 2;
  if(FAILED(e->GetDefaultAudioEndpoint(eRender,eConsole,&d)))return 3;
  if(FAILED(d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(c.GetAddressOf()))))return 4;
  WAVEFORMATEX* format=nullptr;if(FAILED(c->GetMixFormat(&format)))return 5;
  HRESULT hr=c->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_LOOPBACK,10000000,0,format,nullptr);if(FAILED(hr)){std::printf("{\"error\":\"0x%08lx\"}\n",static_cast<ULONG>(hr));return 6;}
  if(FAILED(c->GetService(IID_PPV_ARGS(&capture))))return 7;
  const bool floating=format->wFormatTag==WAVE_FORMAT_IEEE_FLOAT || (format->wFormatTag==WAVE_FORMAT_EXTENSIBLE && reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->SubFormat.Data1==WAVE_FORMAT_IEEE_FLOAT);
  std::printf("{\"kind\":\"render-endpoint-loopback\",\"pid\":%lu,\"endpointSha256\":\"%s\",\"rate\":%lu,\"channels\":%u,\"bits\":%u,\"floating\":%s,\"startUtcMs\":%.3f}\n",GetCurrentProcessId(),EndpointHash(d.Get()).c_str(),format->nSamplesPerSec,format->nChannels,format->wBitsPerSample,floating?"true":"false",UtcMs());std::fflush(stdout);
  if(FAILED(c->Start()))return 8;
  const ULONGLONG start=GetTickCount64();ULONGLONG binStart=start;
  double energy=0,cosine=0,sine=0;UINT64 samples=0;
  while(GetTickCount64()-start<seconds*1000){
    UINT32 packet=0;if(FAILED(capture->GetNextPacketSize(&packet)))return 9;
    while(packet){
      BYTE* data=nullptr;UINT32 frames=0;DWORD flags=0;UINT64 pos=0,qpc=0;
      if(FAILED(capture->GetBuffer(&data,&frames,&flags,&pos,&qpc)))return 10;
      for(UINT32 f=0;f<frames;++f){
        double mono=0;
        for(WORD ch=0;ch<format->nChannels;++ch){
          double value=0;const size_t i=static_cast<size_t>(f)*format->nChannels+ch;
          if(!(flags&AUDCLNT_BUFFERFLAGS_SILENT)){
            if(floating && format->wBitsPerSample==32)value=reinterpret_cast<float*>(data)[i];
            else if(format->wBitsPerSample==16)value=reinterpret_cast<short*>(data)[i]/32768.0;
            else if(format->wBitsPerSample==32)value=reinterpret_cast<LONG*>(data)[i]/2147483648.0;
          }
          mono+=value/format->nChannels;
        }
        const double phase=2*3.141592653589793*660*(pos+f)/format->nSamplesPerSec;
        energy+=mono*mono;cosine+=mono*std::cos(phase);sine+=mono*std::sin(phase);++samples;
      }
      capture->ReleaseBuffer(frames);capture->GetNextPacketSize(&packet);
    }
    if(GetTickCount64()-binStart>=200){
      std::printf("{\"utcMs\":%.3f,\"frames\":%llu,\"rms\":%.9f,\"pilotAmplitude\":%.9f}\n",UtcMs(),samples,samples?std::sqrt(energy/samples):0,samples?2*std::sqrt(cosine*cosine+sine*sine)/samples:0);std::fflush(stdout);
      samples=0;energy=cosine=sine=0;binStart=GetTickCount64();
    }
    Sleep(5);
  }
  c->Stop();CoTaskMemFree(format);return 0;
}
