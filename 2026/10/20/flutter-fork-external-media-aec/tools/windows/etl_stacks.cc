#define UNICODE
#define _UNICODE
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>
#include <iostream>
#include <vector>
#include <string>
DWORD target=0;uint64_t events=0,stackevents=0;
std::string utf(const wchar_t*p){if(!p)return{};int n=WideCharToMultiByte(CP_UTF8,0,p,-1,nullptr,0,nullptr,nullptr);std::string s(n,0);WideCharToMultiByte(CP_UTF8,0,p,-1,s.data(),n,nullptr,nullptr);s.pop_back();return s;}
void quoted(const std::string&s){std::cout<<'"';for(auto c:s){if(c=='"'||c=='\\')std::cout<<'\\';if(static_cast<unsigned char>(c)>=32)std::cout<<c;}std::cout<<'"';}
void WINAPI event(PEVENT_RECORD r){if(r->EventHeader.ProcessId!=target)return;events++;std::vector<uint64_t> addresses;for(USHORT i=0;i<r->ExtendedDataCount;i++){auto&d=r->ExtendedData[i];if(d.ExtType==EVENT_HEADER_EXT_TYPE_STACK_TRACE64&&d.DataSize>=8){auto p=reinterpret_cast<const uint64_t*>(d.DataPtr);for(int j=1;j<d.DataSize/8;j++)addresses.push_back(p[j]);}if(d.ExtType==EVENT_HEADER_EXT_TYPE_STACK_TRACE32&&d.DataSize>=8){auto p=reinterpret_cast<const uint32_t*>(d.DataPtr);for(int j=2;j<d.DataSize/4;j++)addresses.push_back(p[j]);}}
ULONG bytes=0;TdhGetEventInformation(r,0,nullptr,nullptr,&bytes);std::vector<BYTE>b(bytes);auto info=reinterpret_cast<TRACE_EVENT_INFO*>(b.data());if(TdhGetEventInformation(r,0,nullptr,info,&bytes)!=ERROR_SUCCESS)return;
auto name=[&](ULONG offset){return offset?utf(reinterpret_cast<wchar_t*>(b.data()+offset)):std::string();};auto provider=name(info->ProviderNameOffset);if(provider.find("Audio")==std::string::npos)return;if(addresses.size())stackevents++;
wchar_t guid[40];StringFromGUID2(r->EventHeader.ProviderId,guid,40);std::cout<<"{\"providerGuid\":";quoted(utf(guid));std::cout<<",\"pid\":"<<target<<",\"tid\":"<<r->EventHeader.ThreadId<<",\"qpc\":"<<r->EventHeader.TimeStamp.QuadPart<<",\"provider\":";quoted(provider);std::cout<<",\"event\":";quoted(name(info->EventNameOffset));std::cout<<",\"id\":"<<r->EventHeader.EventDescriptor.Id<<",\"stack\":[";for(size_t i=0;i<addresses.size();i++){if(i)std::cout<<',';std::cout<<'"'<<"0x"<<std::hex<<addresses[i]<<std::dec<<'"';}std::cout<<"]}\n";
}
int wmain(int argc,wchar_t**argv){if(argc!=3)return 2;target=wcstoul(argv[2],nullptr,10);EVENT_TRACE_LOGFILEW log{};log.LogFileName=argv[1];log.ProcessTraceMode=PROCESS_TRACE_MODE_EVENT_RECORD|PROCESS_TRACE_MODE_RAW_TIMESTAMP;log.EventRecordCallback=event;auto trace=OpenTraceW(&log);if(trace==INVALID_PROCESSTRACE_HANDLE)return 3;auto hr=ProcessTrace(&trace,1,nullptr,nullptr);CloseTrace(trace);if(hr)std::cerr<<"events="<<events<<" audioStackEvents="<<stackevents<<" processTrace="<<hr<<"\n";return hr?1:0;}
