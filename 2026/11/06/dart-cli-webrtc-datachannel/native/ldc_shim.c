// Bridges libdatachannel's C callbacks to one Dart NativeCallable.listener.
//
// libdatachannel calls back on its own threads with strings that live only
// for the call. A listener runs later on the Dart isolate, so every string is
// copied with malloc here and freed by Dart (ldc_free).
#include <stdlib.h>
#include <string.h>

#include <rtc/rtc.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

enum {
  EV_DESCRIPTION = 1, // id=pc, text="<type>\n<sdp>"
  EV_CANDIDATE = 2,   // id=pc, text="<mid>\n<candidate>"
  EV_STATE = 3,       // id=pc, a=rtcState
  EV_DATACHANNEL = 4, // id=pc, a=dc
  EV_OPEN = 5,        // id=dc
  EV_CLOSED = 6,      // id=dc
  EV_ERROR = 7,       // id=dc, text=error
  EV_MESSAGE = 8,     // id=dc, a=1 text / 0 binary, text=bytes, size
  EV_ICE_STATE = 9,   // id=pc, a=rtcIceState
};

typedef void (*ldc_event_fn)(int kind, int id, int a, char *text, int size);
static ldc_event_fn g_event = NULL;

static char *copy(const char *p, int n) {
  char *s = malloc((size_t)n + 1);
  if (n > 0) memcpy(s, p, (size_t)n);
  s[n] = 0;
  return s;
}

static char *join(const char *a, const char *b) {
  size_t na = a ? strlen(a) : 0, nb = b ? strlen(b) : 0;
  char *s = malloc(na + nb + 2);
  if (na) memcpy(s, a, na);
  s[na] = '\n';
  if (nb) memcpy(s + na + 1, b, nb);
  s[na + nb + 1] = 0;
  return s;
}

static void on_description(int pc, const char *sdp, const char *type, void *ptr) {
  char *s = join(type, sdp);
  g_event(EV_DESCRIPTION, pc, 0, s, (int)strlen(s));
}

static void on_candidate(int pc, const char *cand, const char *mid, void *ptr) {
  char *s = join(mid, cand);
  g_event(EV_CANDIDATE, pc, 0, s, (int)strlen(s));
}

static void on_state(int pc, rtcState state, void *ptr) { g_event(EV_STATE, pc, state, NULL, 0); }
static void on_ice_state(int pc, rtcIceState state, void *ptr) { g_event(EV_ICE_STATE, pc, state, NULL, 0); }
static void on_open(int id, void *ptr) { g_event(EV_OPEN, id, 0, NULL, 0); }
static void on_closed(int id, void *ptr) { g_event(EV_CLOSED, id, 0, NULL, 0); }

static void on_error(int id, const char *error, void *ptr) {
  int n = error ? (int)strlen(error) : 0;
  g_event(EV_ERROR, id, 0, copy(error ? error : "", n), n);
}

static void on_message(int id, const char *message, int size, void *ptr) {
  // size < 0: a null-terminated string message.
  int text = size < 0;
  int n = text ? (int)strlen(message) : size;
  g_event(EV_MESSAGE, id, text, copy(message, n), n);
}

EXPORT void ldc_init(ldc_event_fn fn) { g_event = fn; }

EXPORT void ldc_free(char *p) { free(p); }

EXPORT int ldc_attach_dc(int dc) {
  rtcSetOpenCallback(dc, on_open);
  rtcSetClosedCallback(dc, on_closed);
  rtcSetErrorCallback(dc, on_error);
  return rtcSetMessageCallback(dc, on_message);
}

static void on_datachannel(int pc, int dc, void *ptr) {
  ldc_attach_dc(dc);
  g_event(EV_DATACHANNEL, pc, dc, NULL, 0);
}

EXPORT int ldc_attach_pc(int pc) {
  rtcSetLocalDescriptionCallback(pc, on_description);
  rtcSetLocalCandidateCallback(pc, on_candidate);
  rtcSetStateChangeCallback(pc, on_state);
  rtcSetIceStateChangeCallback(pc, on_ice_state);
  return rtcSetDataChannelCallback(pc, on_datachannel);
}

// rtcCreatePeerConnection with only the fields the lab sets.
EXPORT int ldc_create_pc(const char **ice_servers, int count) {
  rtcConfiguration config;
  memset(&config, 0, sizeof(config));
  config.iceServers = ice_servers;
  config.iceServersCount = count;
  return rtcCreatePeerConnection(&config);
}

// An ordered, reliable channel, as the app makes.
EXPORT int ldc_create_dc(int pc, const char *label) {
  rtcDataChannelInit init;
  memset(&init, 0, sizeof(init));
  int dc = rtcCreateDataChannelEx(pc, label, &init);
  if (dc >= 0) ldc_attach_dc(dc);
  return dc;
}
