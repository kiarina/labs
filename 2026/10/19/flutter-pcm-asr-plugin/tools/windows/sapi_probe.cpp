// SAPI in-process recognition from memory PCM, with any recognizer token.
// Plain COM, no ATL (sphelper.h needs atlbase.h, which this PC lacks).
//
//   sapi_probe.exe list
//   sapi_probe.exe run <token-id> <dir-with-segment-N.wav> [passes]
//
// Token ids come from `list`: the classic SPCAT_RECOGNIZERS category and the
// OneCore category (HKLM\SOFTWARE\Microsoft\Speech_OneCore\Recognizers).
// Prints `PCM_ASR {json}` lines like the Flutter example does.
#include <initguid.h>
#include <windows.h>
#include <sapi.h>
#include <sapiddk.h>

#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

static std::string utf8(const wchar_t* w) {
  if (!w) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  std::string s(n > 0 ? n - 1 : 0, '\0');
  if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

static std::string json(const std::string& s) {
  std::string o = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') { o += '\\'; o += c; }
    else if (c == '\n') o += "\\n";
    else o += c;
  }
  return o + "\"";
}

template <class T> struct Ptr {
  T* p = nullptr;
  ~Ptr() { if (p) p->Release(); }
  T** operator&() { return &p; }
  T* operator->() { return p; }
  operator T*() { return p; }
};

static void listCategory(const wchar_t* category) {
  Ptr<ISpObjectTokenCategory> cat;
  if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL, IID_ISpObjectTokenCategory, (void**)&cat))) return;
  if (FAILED(cat->SetId(category, FALSE))) { printf("  (cannot open %s)\n", utf8(category).c_str()); return; }
  Ptr<IEnumSpObjectTokens> e;
  if (FAILED(cat->EnumTokens(nullptr, nullptr, &e))) { printf("  (cannot enumerate %s)\n", utf8(category).c_str()); return; }
  ISpObjectToken* t = nullptr;
  while (e->Next(1, &t, nullptr) == S_OK) {
    LPWSTR id = nullptr; t->GetId(&id);
    LPWSTR desc = nullptr;
    ISpDataKey* key = t; key->GetStringValue(nullptr, &desc);
    printf("  %s | %s\n", utf8(id).c_str(), utf8(desc).c_str());
    CoTaskMemFree(id); CoTaskMemFree(desc);
    t->Release(); t = nullptr;
  }
}

static std::vector<BYTE> readFile(const std::wstring& path) {
  std::vector<BYTE> data;
  HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
  if (h == INVALID_HANDLE_VALUE) return data;
  DWORD size = GetFileSize(h, nullptr); data.resize(size);
  DWORD got = 0; ReadFile(h, data.data(), size, &got, nullptr); CloseHandle(h);
  return data;
}

#define FATAL(step, hr) { printf("PCM_ASR {\"kind\":\"fatal\",\"error\":\"%s %08lx\"}\n", step, (unsigned long)(hr)); return 1; }
#define SEGERR(code, step, hr) { printf("PCM_ASR {\"kind\":\"error\",\"id\":\"segment-%d#%d\",\"code\":\"%s\",\"message\":\"%s %08lx\"}\n", seg, trial, code, step, (unsigned long)(hr)); continue; }

int wmain(int argc, wchar_t** argv) {
  SetConsoleOutputCP(CP_UTF8);
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (argc < 2) { printf("usage: list | run <token> <dir> [passes]\n"); return 2; }
  if (wcscmp(argv[1], L"list") == 0) {
    printf("SPCAT_RECOGNIZERS:\n"); listCategory(SPCAT_RECOGNIZERS);
    printf("OneCore:\n"); listCategory(L"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech_OneCore\\Recognizers");
    return 0;
  }
  if (argc < 4) { printf("usage: run <token> <dir> [passes]\n"); return 2; }
  std::wstring tokenId = argv[2], dir = argv[3];
  int passes = argc > 4 ? _wtoi(argv[4]) : 3;

  Ptr<ISpObjectToken> token;
  HRESULT hr = CoCreateInstance(CLSID_SpObjectToken, nullptr, CLSCTX_ALL, IID_ISpObjectToken, (void**)&token);
  if (FAILED(hr)) FATAL("CoCreate token", hr);
  hr = token->SetId(nullptr, tokenId.c_str(), FALSE);
  if (FAILED(hr)) FATAL("token SetId", hr);
  Ptr<ISpRecognizer> recognizer;
  hr = CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL, IID_ISpRecognizer, (void**)&recognizer);
  if (FAILED(hr)) FATAL("CoCreate recognizer", hr);
  hr = recognizer->SetRecognizer(token);
  if (FAILED(hr)) FATAL("SetRecognizer", hr);
  Ptr<ISpRecoContext> context;
  hr = recognizer->CreateRecoContext(&context);
  if (FAILED(hr)) FATAL("CreateRecoContext", hr);
  context->SetNotifyWin32Event();
  ULONGLONG interest = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_FALSE_RECOGNITION) | SPFEI(SPEI_END_SR_STREAM) | SPFEI(SPEI_HYPOTHESIS);
  context->SetInterest(interest, interest);
  Ptr<ISpRecoGrammar> grammar;
  hr = context->CreateGrammar(1, &grammar);
  if (FAILED(hr)) FATAL("CreateGrammar", hr);
  // Try the dictation topic variants; OneCore engines may not expose the default one through SAPI.
  const wchar_t* topics[] = { nullptr, L"Dictation", L"dictation", L"SPTOPIC_DICTATION", L"Spelling" };
  hr = E_FAIL;
  for (const wchar_t* topic : topics) {
    for (SPLOADOPTIONS opt : { SPLO_STATIC, SPLO_DYNAMIC }) {
      hr = grammar->LoadDictation(topic, opt);
      printf("PCM_ASR {\"kind\":\"probe\",\"step\":\"LoadDictation\",\"topic\":%s,\"dynamic\":%s,\"hr\":\"%08lx\"}\n", topic ? json(utf8(topic)).c_str() : "null", opt == SPLO_DYNAMIC ? "true" : "false", (unsigned long)hr);
      if (SUCCEEDED(hr)) break;
    }
    if (SUCCEEDED(hr)) break;
  }
  if (FAILED(hr)) {
    // Last resort: a tiny dynamic rule grammar, to see whether the engine recognizes anything at all through SAPI.
    SPSTATEHANDLE rule;
    hr = grammar->GetRule(L"root", 0, SPRAF_TopLevel | SPRAF_Active | SPRAF_Dynamic, TRUE, &rule);
    if (SUCCEEDED(hr)) hr = grammar->AddWordTransition(rule, nullptr, L"\u3082\u3057\u3082\u3057", L" ", SPWT_LEXICAL, 1, nullptr);
    if (SUCCEEDED(hr)) hr = grammar->Commit(0);
    if (SUCCEEDED(hr)) hr = grammar->SetRuleState(nullptr, nullptr, SPRS_ACTIVE);
    printf("PCM_ASR {\"kind\":\"probe\",\"step\":\"rule-grammar\",\"hr\":\"%08lx\"}\n", (unsigned long)hr);
    if (FAILED(hr)) FATAL("LoadDictation", hr);
  }
  printf("PCM_ASR {\"kind\":\"platform\",\"os\":\"windows\",\"engine\":\"sapi-inproc\",\"token\":%s}\n", json(utf8(tokenId.c_str())).c_str());
  fflush(stdout);

  WAVEFORMATEX fmt = {};
  fmt.wFormatTag = WAVE_FORMAT_PCM; fmt.nChannels = 1; fmt.nSamplesPerSec = 16000;
  fmt.wBitsPerSample = 16; fmt.nBlockAlign = 2; fmt.nAvgBytesPerSec = 32000;

  for (int trial = 0; trial < passes; trial++) {
    for (int k = 0; k < 6; k++) {
      int seg = trial == 2 ? 6 - k : k + 1;
      std::wstring path = dir + L"\\segment-" + std::to_wstring(seg) + L".wav";
      std::vector<BYTE> wav = readFile(path);
      if (wav.size() <= 44) SEGERR("invalidPcm", "cannot read wav", 0);
      auto t0 = std::chrono::steady_clock::now();
      Ptr<ISpStream> stream;
      hr = CoCreateInstance(CLSID_SpStream, nullptr, CLSCTX_ALL, IID_ISpStream, (void**)&stream);
      if (FAILED(hr)) SEGERR("engineFailure", "CoCreate SpStream", hr);
      HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, wav.size() - 44);
      memcpy(GlobalLock(h), wav.data() + 44, wav.size() - 44); GlobalUnlock(h);
      Ptr<IStream> mem;
      CreateStreamOnHGlobal(h, TRUE, &mem);
      hr = stream->SetBaseStream(mem, SPDFID_WaveFormatEx, &fmt);
      if (FAILED(hr)) SEGERR("engineFailure", "SetBaseStream", hr);
      hr = recognizer->SetInput(stream, TRUE);
      if (FAILED(hr)) SEGERR("engineFailure", "SetInput", hr);
      std::string text; std::string hypo; int finals = 0;
      hr = grammar->SetDictationState(SPRS_ACTIVE);
      if (FAILED(hr)) SEGERR("engineFailure", "SetDictationState", hr);
      bool ended = false; bool timedOut = false;
      while (!ended) {
        if (context->WaitForNotifyEvent(20000) != S_OK) { timedOut = true; break; }
        SPEVENT ev; ULONG got = 0;
        while (context->GetEvents(1, &ev, &got) == S_OK && got == 1) {
          if (ev.eEventId == SPEI_RECOGNITION || ev.eEventId == SPEI_HYPOTHESIS || ev.eEventId == SPEI_FALSE_RECOGNITION) {
            if (ev.elParamType == SPET_LPARAM_IS_OBJECT && ev.lParam) {
              ISpRecoResult* r = nullptr;
              if (SUCCEEDED(((IUnknown*)ev.lParam)->QueryInterface(IID_ISpRecoResult, (void**)&r)) && r) {
                LPWSTR s = nullptr;
                if (SUCCEEDED(r->GetText(SP_GETWHOLEPHRASE, SP_GETWHOLEPHRASE, TRUE, &s, nullptr)) && s) {
                  if (ev.eEventId == SPEI_RECOGNITION) { text += utf8(s); finals++; } else hypo = utf8(s);
                  CoTaskMemFree(s);
                }
                r->Release();
              }
            }
          } else if (ev.eEventId == SPEI_END_SR_STREAM) {
            ended = true;
          }
          if (ev.elParamType == SPET_LPARAM_IS_OBJECT && ev.lParam) ((IUnknown*)ev.lParam)->Release();
          else if (ev.elParamType == SPET_LPARAM_IS_POINTER && ev.lParam) CoTaskMemFree((void*)ev.lParam);
        }
      }
      grammar->SetDictationState(SPRS_INACTIVE);
      double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
      if (timedOut) { printf("PCM_ASR {\"kind\":\"error\",\"id\":\"segment-%d#%d\",\"code\":\"timeout\",\"message\":\"no end-of-stream in 20 s; text so far %s\"}\n", seg, trial, json(text).c_str()); fflush(stdout); continue; }
      printf("PCM_ASR {\"kind\":\"result\",\"id\":\"segment-%d#%d\",\"segment_id\":\"segment-%d\",\"trial\":%d,\"text\":%s,\"last_hypothesis\":%s,\"final_results\":%d,\"engine\":\"sapi-inproc\",\"locale\":\"ja-JP\",\"elapsed_ms\":%.1f,\"round_trip_ms\":%.1f,\"id_matches\":true,\"ranges\":[]}\n",
             seg, trial, seg, trial, json(text).c_str(), json(hypo).c_str(), finals, ms, ms);
      fflush(stdout);
    }
  }
  printf("PCM_ASR {\"kind\":\"done\",\"ok\":true}\n");
  return 0;
}
