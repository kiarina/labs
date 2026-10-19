#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;
int main(){HRESULT h=CoInitializeEx(nullptr,COINIT_MULTITHREADED);if(FAILED(h))return 1;
{ComPtr<IMMDeviceEnumerator> e;ComPtr<IMMDevice>d;ComPtr<IAudioClient>c;ComPtr<IAudioCaptureClient>cc;WAVEFORMATEX*f=nullptr;
h=CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&e));if(SUCCEEDED(h))h=e->GetDefaultAudioEndpoint(eCapture,eConsole,&d);if(SUCCEEDED(h))h=d->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(c.GetAddressOf()));if(SUCCEEDED(h))h=c->GetMixFormat(&f);
std::cout<<"pid="<<GetCurrentProcessId()<<" beforeInitialize"<<std::endl;
if(SUCCEEDED(h))h=c->Initialize(AUDCLNT_SHAREMODE_SHARED,0,200000,0,f,nullptr);std::cout<<"Initialize="<<std::hex<<h<<std::endl;
if(SUCCEEDED(h))h=c->GetService(IID_PPV_ARGS(&cc));if(SUCCEEDED(h))h=c->Start();std::cout<<"Start="<<std::hex<<h<<std::endl;
ULONGLONG until=GetTickCount64()+2000;UINT64 count=0;while(SUCCEEDED(h)&&GetTickCount64()<until){UINT32 n=0;h=cc->GetNextPacketSize(&n);if(FAILED(h))break;if(!n){Sleep(2);continue;}BYTE*p=nullptr;DWORD flags=0;h=cc->GetBuffer(&p,&n,&flags,nullptr,nullptr);if(SUCCEEDED(h)){count+=n;h=cc->ReleaseBuffer(n);}}
if(c)c->Stop();if(f)CoTaskMemFree(f);std::cout<<"frames="<<std::dec<<count<<" hr="<<std::hex<<h<<std::endl;}
CoUninitialize();return FAILED(h)?1:0;}
