#include "aec_engine.h"
#include <vector>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <iomanip>
#include <algorithm>
constexpr int rate=48000,length=rate*18,delay=3840;
std::vector<int16_t> far_signal(length),near_signal(length);
static int chosen_preset=0;
static double capture_scale=1;
struct Result {double inputRms,outputRms,erle,correlation=0,gain=0,echoGain=0,improvement=0;int lag=0;};
Result run(bool echo,bool local){
 std::vector<int16_t> mic(length),clean(length);int16_t zero[480]{};
 for(int i=0;i<length;i++)mic[i]=static_cast<int16_t>(std::floor(capture_scale*((echo&&i>=delay?0.5*far_signal[i-delay]:0)+(local?near_signal[i]:0))+0.5));
 void* h=aec_create_config(1,chosen_preset);if(!h)std::exit(2);
 for(int i=0;i<length;i+=480){if(aec_reverse(h,echo?far_signal.data()+i:zero,480)||aec_capture(h,mic.data()+i,clean.data()+i,480,80))std::exit(3);}
 aec_destroy(h);const int start=length-rate*3;double ip=0,op=0;
 for(int i=start;i<length;i++){ip+=double(mic[i])*mic[i];op+=double(clean[i])*clean[i];}
 Result r{std::sqrt(ip/(length-start)),std::sqrt(op/(length-start)),10*std::log10(ip/std::max(op,1.0))};
 if(local)for(int lag=0;lag<=960;lag++){double xy=0,xx=0,yy=0;for(int i=start+lag;i<length;i++){double x=capture_scale*near_signal[i-lag],y=clean[i];xy+=x*y;xx+=x*x;yy+=y*y;}double c=xy/std::sqrt(xx*yy);if(c>r.correlation){r.correlation=c;r.lag=lag;r.gain=xy/xx;}}
 if(echo&&local){double xy=0,xx=0;for(int i=start+r.lag+delay;i<length;i++){double x=far_signal[i-r.lag-delay],y=clean[i]-r.gain*capture_scale*near_signal[i-r.lag];xy+=x*y;xx+=x*x;}r.echoGain=xy/xx;r.improvement=20*std::log10((0.5*capture_scale)/std::max(std::abs(r.echoGain),1e-12));}
 return r;
}
void print(const char* name,const Result&r){std::cout<<'"'<<name<<"\":{\"inputRms\":"<<r.inputRms<<",\"outputRms\":"<<r.outputRms<<",\"erleDb\":"<<r.erle<<",\"correlation\":"<<r.correlation<<",\"gain\":"<<r.gain<<",\"lag\":"<<r.lag<<",\"echoGain\":"<<r.echoGain<<",\"echoImprovementDb\":"<<r.improvement<<'}';}
int main(int argc,char**argv){chosen_preset=argc>1?std::atoi(argv[1]):0;capture_scale=argc>2?std::atof(argv[2]):1;uint32_t seed=123456789;auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return double(seed)/4294967296.0*2-1;};double f=0,n=0;
 for(int i=0;i<length;i++){f=.8*f+.2*random();n=.75*n+.25*random();far_signal[i]=static_cast<int16_t>(std::floor(f*13000*(.65+.35*std::sin(double(i)/rate*6))+.5));near_signal[i]=static_cast<int16_t>(std::floor(n*9000*(.6+.4*std::sin(double(i)/rate*9))+.5));}
 Result a=run(true,false),b=run(false,true),c=run(true,true);bool pass=a.erle>=15&&b.correlation>=.95&&std::abs(20*std::log10(b.gain))<=3&&c.gain>=std::pow(10.,-6./20)&&c.improvement>=6;
 std::cout<<std::setprecision(15)<<"{\"kind\":\"digital-aec3-native\",\"sampleRate\":48000,\"seconds\":18,\"echoDelayMs\":80,\"echoGain\":0.5,";std::cout<<"\"preset\":"<<chosen_preset<<",\"captureScale\":"<<capture_scale<<',';print("farOnly",a);std::cout<<',';print("nearOnly",b);std::cout<<',';print("doubleTalk",c);std::cout<<",\"pass\":"<<(pass?"true":"false")<<"}\n";return pass?0:1;
}
