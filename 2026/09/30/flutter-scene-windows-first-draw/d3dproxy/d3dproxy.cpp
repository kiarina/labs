// A stand-in d3dcompiler_47.dll. Placed next to an app's .exe, it is loaded
// instead of the system one (which it forwards to, as d3dcompiler_47_sys.dll
// in the same folder). D3DCompile and D3DCompile2 are wrapped to:
//
//   D3DPROXY_LOG=<file>    append one CSV line per compile:
//                          start_ms,duration_ms,key,source_bytes,target,entry,flags1,cache
//   D3DPROXY_DUMP=<dir>    save each HLSL source as <key>.hlsl
//   D3DPROXY_CACHE=<dir>   keep compiled bytecode on disk (<key>.bin) and serve it
//                          on later calls, across launches: a stand-in for a
//                          persistent program cache such as EGL's blob cache
//   D3DPROXY_OPT=0|1|2|3|skip  replace the optimization flags ANGLE passes
#include <windows.h>
#include <d3dcompiler.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "forwards.h"

namespace {

using CompileFn = HRESULT(WINAPI*)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO*,
                                   ID3DInclude*, LPCSTR, LPCSTR, UINT, UINT,
                                   ID3DBlob**, ID3DBlob**);
using Compile2Fn = HRESULT(WINAPI*)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO*,
                                    ID3DInclude*, LPCSTR, LPCSTR, UINT, UINT, UINT,
                                    LPCVOID, SIZE_T, ID3DBlob**, ID3DBlob**);
using CreateBlobFn = HRESULT(WINAPI*)(SIZE_T, ID3DBlob**);

HMODULE real() {
  static HMODULE module = [] {
    wchar_t path[MAX_PATH];
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&real), &self);
    GetModuleFileNameW(self, path, MAX_PATH);
    std::wstring dir(path);
    dir = dir.substr(0, dir.find_last_of(L"\\/") + 1);
    return LoadLibraryW((dir + L"d3dcompiler_47_sys.dll").c_str());
  }();
  return module;
}

template <typename T>
T fn(const char* name) {
  return reinterpret_cast<T>(GetProcAddress(real(), name));
}

std::string env(const char* name) {
  char buf[1024];
  DWORD n = GetEnvironmentVariableA(name, buf, sizeof(buf));
  return (n > 0 && n < sizeof(buf)) ? std::string(buf, n) : std::string();
}

uint64_t fnv(uint64_t h, const void* data, size_t size) {
  auto p = static_cast<const uint8_t*>(data);
  for (size_t i = 0; i < size; i++) h = (h ^ p[i]) * 1099511628211ull;
  return h;
}

uint64_t keyOf(LPCVOID src, SIZE_T size, const D3D_SHADER_MACRO* defines,
               LPCSTR entry, LPCSTR target, UINT flags1, UINT flags2) {
  uint64_t h = 1469598103934665603ull;
  h = fnv(h, src, size);
  for (auto d = defines; d && d->Name; d++) {
    h = fnv(h, d->Name, strlen(d->Name) + 1);
    if (d->Definition) h = fnv(h, d->Definition, strlen(d->Definition) + 1);
  }
  if (entry) h = fnv(h, entry, strlen(entry) + 1);
  if (target) h = fnv(h, target, strlen(target) + 1);
  h = fnv(h, &flags1, sizeof(flags1));
  h = fnv(h, &flags2, sizeof(flags2));
  return h;
}

UINT applyOpt(UINT flags) {
  std::string opt = env("D3DPROXY_OPT");
  if (opt.empty()) return flags;
  const UINT mask = D3DCOMPILE_SKIP_OPTIMIZATION | D3DCOMPILE_OPTIMIZATION_LEVEL3;
  flags &= ~mask;
  if (opt == "0") flags |= D3DCOMPILE_OPTIMIZATION_LEVEL0;
  else if (opt == "1") flags |= D3DCOMPILE_OPTIMIZATION_LEVEL1;
  else if (opt == "2") flags |= D3DCOMPILE_OPTIMIZATION_LEVEL2;
  else if (opt == "3") flags |= D3DCOMPILE_OPTIMIZATION_LEVEL3;
  else if (opt == "skip") flags |= D3DCOMPILE_SKIP_OPTIMIZATION;
  return flags;
}

double nowMs() {
  static LARGE_INTEGER freq, start;
  static bool init = [] {
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    return true;
  }();
  (void)init;
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return 1000.0 * (t.QuadPart - start.QuadPart) / freq.QuadPart;
}

bool readFile(const std::string& path, std::vector<char>& out) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  out.resize(n);
  bool ok = fread(out.data(), 1, n, f) == static_cast<size_t>(n);
  fclose(f);
  return ok;
}

void writeFile(const std::string& path, const void* data, size_t size) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return;
  fwrite(data, 1, size, f);
  fclose(f);
}

void logLine(double start, double dur, uint64_t key, SIZE_T size, LPCSTR target,
             LPCSTR entry, UINT flags, const char* cache) {
  std::string path = env("D3DPROXY_LOG");
  if (path.empty()) return;
  FILE* f = fopen(path.c_str(), "a");
  if (!f) return;
  fprintf(f, "%.1f,%.1f,%016llx,%zu,%s,%s,0x%x,%s\n", start, dur,
          static_cast<unsigned long long>(key), static_cast<size_t>(size),
          target ? target : "", entry ? entry : "", flags, cache);
  fclose(f);
}

// Shared by D3DCompile and D3DCompile2: the cache lookup, the compile, and
// the log line. `compile` runs the real call with the (possibly rewritten)
// flags.
template <typename Compile>
HRESULT wrap(LPCVOID src, SIZE_T size, const D3D_SHADER_MACRO* defines,
             LPCSTR entry, LPCSTR target, UINT flags1, UINT flags2,
             ID3DBlob** code, ID3DBlob** errors, Compile compile) {
  const double start = nowMs();
  flags1 = applyOpt(flags1);
  const uint64_t key = keyOf(src, size, defines, entry, target, flags1, flags2);
  char name[32];
  snprintf(name, sizeof(name), "%016llx", static_cast<unsigned long long>(key));

  std::string dump = env("D3DPROXY_DUMP");
  if (!dump.empty()) writeFile(dump + "\\" + name + ".hlsl", src, size);

  std::string cache = env("D3DPROXY_CACHE");
  if (!cache.empty() && code) {
    std::vector<char> bytes;
    if (readFile(cache + "\\" + name + ".bin", bytes)) {
      ID3DBlob* blob = nullptr;
      if (SUCCEEDED(fn<CreateBlobFn>("D3DCreateBlob")(bytes.size(), &blob))) {
        memcpy(blob->GetBufferPointer(), bytes.data(), bytes.size());
        *code = blob;
        if (errors) *errors = nullptr;
        logLine(start, nowMs() - start, key, size, target, entry, flags1, "hit");
        return S_OK;
      }
    }
  }

  HRESULT hr = compile(flags1);
  if (SUCCEEDED(hr) && !cache.empty() && code && *code) {
    writeFile(cache + "\\" + name + ".bin", (*code)->GetBufferPointer(),
              (*code)->GetBufferSize());
  }
  logLine(start, nowMs() - start, key, size, target, entry, flags1,
          cache.empty() ? "off" : "miss");
  return hr;
}

}  // namespace

extern "C" HRESULT WINAPI Proxy_D3DCompile(
    LPCVOID src, SIZE_T size, LPCSTR name, const D3D_SHADER_MACRO* defines,
    ID3DInclude* include, LPCSTR entry, LPCSTR target, UINT flags1, UINT flags2,
    ID3DBlob** code, ID3DBlob** errors) {
  return wrap(src, size, defines, entry, target, flags1, flags2, code, errors,
              [&](UINT f1) {
                return fn<CompileFn>("D3DCompile")(src, size, name, defines, include,
                                                  entry, target, f1, flags2, code,
                                                  errors);
              });
}

extern "C" HRESULT WINAPI Proxy_D3DCompile2(
    LPCVOID src, SIZE_T size, LPCSTR name, const D3D_SHADER_MACRO* defines,
    ID3DInclude* include, LPCSTR entry, LPCSTR target, UINT flags1, UINT flags2,
    UINT secondaryFlags, LPCVOID secondary, SIZE_T secondarySize, ID3DBlob** code,
    ID3DBlob** errors) {
  return wrap(src, size, defines, entry, target, flags1, flags2, code, errors,
              [&](UINT f1) {
                return fn<Compile2Fn>("D3DCompile2")(
                    src, size, name, defines, include, entry, target, f1, flags2,
                    secondaryFlags, secondary, secondarySize, code, errors);
              });
}
