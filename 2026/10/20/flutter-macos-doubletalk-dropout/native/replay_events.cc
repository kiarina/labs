#include "aec_engine.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>
template<class T>std::vector<T> read(const std::string& path){std::ifstream f(path,std::ios::binary|std::ios::ate);if(!f)std::exit(2);auto n=f.tellg();if(n<0||size_t(n)%sizeof(T))std::exit(3);std::vector<T> x(size_t(n)/sizeof(T));f.seekg(0);f.read(reinterpret_cast<char*>(x.data()),n);return x;}
int main(int argc,char**argv){if(argc!=7)return 1;auto mic=read<int16_t>(argv[1]),ref=read<int16_t>(argv[2]);auto events=read<uint8_t>(argv[3]);int preset=std::atoi(argv[4]);void* h=aec_create_config(1,preset);if(!h)return 4;std::ofstream out(argv[5],std::ios::binary);size_t c=0,r=0;int16_t block[480];for(auto event:events){if(event==1){if(r+480>ref.size())return 5;if(aec_reverse(h,ref.data()+r,480))return 6;r+=480;}else if(event==2){if(c+480>mic.size())return 7;if(aec_capture(h,mic.data()+c,block,480,std::atoi(argv[6])))return 8;out.write(reinterpret_cast<char*>(block),sizeof(block));c+=480;}else return 9;}aec_destroy(h);std::cout<<"{\"captureSamples\":"<<c<<",\"reverseSamples\":"<<r<<"}\n";return 0;}
