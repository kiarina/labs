#include "media_taps_plugin.h"

#include <flutter/standard_method_codec.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "flutter_webrtc.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace media_taps {

namespace {

constexpr size_t kMaxFrames = 8;
constexpr size_t kMaxPcmBytes = 96000;

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

const EncodableValue *Arg(const EncodableMap &args, const char *key) {
  auto it = args.find(EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

}  // namespace

// Counters are summarised under a mutex; the sinks are called on WebRTC's
// capture / decode / audio threads, while poll() runs on the platform thread.
class Tap {
 public:
  Tap(int id, std::string kind) : id_(id), kind_(std::move(kind)) {}
  virtual ~Tap() = default;
  virtual EncodableMap Drain() = 0;

 protected:
  void Inc(const std::string &key, int64_t by = 1) {
    counters_[key] += by;
  }
  EncodableMap Counters() const {
    EncodableMap map;
    for (const auto &[k, v] : counters_) map[EncodableValue(k)] = EncodableValue(v);
    for (const auto &[k, v] : text_) map[EncodableValue(k)] = EncodableValue(v);
    return map;
  }

  const int id_;
  const std::string kind_;
  std::mutex lock_;
  std::map<std::string, int64_t> counters_;
  std::map<std::string, std::string> text_;
};

class VideoTap : public Tap,
                 public libwebrtc::RTCVideoRenderer<
                     libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame>> {
 public:
  VideoTap(int id, libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack> track,
           int convert_width, bool deliver)
      : Tap(id, "video"),
        track_(track),
        convert_width_(convert_width),
        deliver_(deliver) {
    track_->AddRenderer(this);
  }

  ~VideoTap() override { track_->RemoveRenderer(this); }

  void OnFrame(libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> frame) override {
    const int w = frame->width();
    const int h = frame->height();
    std::vector<uint8_t> luma;
    int dw = 0, dh = 0;
    int64_t us = 0;
    if (convert_width_ != 0) {
      const int64_t t0 = NowUs();
      dw = convert_width_ < 0 ? w : convert_width_;
      dh = (h * dw / w) & ~1;
      // DataY() converts to I420 on each call, so take it once. Nearest-
      // neighbour downscale of the Y plane (the other platforms scale with
      // libyuv / the GPU before reading back).
      const uint8_t *y = frame->DataY();
      const int stride = frame->StrideY();
      luma.resize(static_cast<size_t>(dw) * dh);
      for (int row = 0; row < dh; ++row) {
        const uint8_t *src = y + static_cast<size_t>(row * h / dh) * stride;
        uint8_t *dst = luma.data() + static_cast<size_t>(row) * dw;
        for (int col = 0; col < dw; ++col) dst[col] = src[col * w / dw];
      }
      us = NowUs() - t0;
    }
    std::lock_guard<std::mutex> guard(lock_);
    Inc("callbacks");
    counters_["width"] = w;
    counters_["height"] = h;
    counters_["rotation"] = static_cast<int64_t>(frame->rotation());
    text_["bufferType"] = "i420";
    if (convert_width_ != 0) {
      Inc("convertCount");
      Inc("convertUsTotal", us);
      counters_["convertUsMax"] = (std::max)(counters_["convertUsMax"], us);
    }
    if (deliver_ && !luma.empty()) {
      if (queue_.size() >= kMaxFrames) {
        queue_.pop_front();
        Inc("droppedToDart");
      }
      queue_.push_back({dw, dh, std::move(luma)});
    }
  }

  EncodableMap Drain() override {
    std::lock_guard<std::mutex> guard(lock_);
    EncodableList frames;
    for (auto &f : queue_) {
      frames.push_back(EncodableValue(EncodableMap{
          {EncodableValue("width"), EncodableValue(f.width)},
          {EncodableValue("height"), EncodableValue(f.height)},
          {EncodableValue("luma"), EncodableValue(std::move(f.luma))},
      }));
    }
    queue_.clear();
    return EncodableMap{
        {EncodableValue("id"), EncodableValue(id_)},
        {EncodableValue("kind"), EncodableValue(kind_)},
        {EncodableValue("counters"), EncodableValue(Counters())},
        {EncodableValue("frames"), EncodableValue(std::move(frames))},
    };
  }

 private:
  struct Frame {
    int width;
    int height;
    std::vector<uint8_t> luma;
  };
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack> track_;
  const int convert_width_;
  const bool deliver_;
  std::deque<Frame> queue_;
};

// Local tracks only receive data while the track is being sent on a
// connected PeerConnection (see the lab README).
class AudioTap : public Tap, public libwebrtc::AudioTrackSink {
 public:
  AudioTap(int id, libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track,
           bool deliver)
      : Tap(id, "audio"), track_(track), deliver_(deliver) {
    track_->AddSink(this);
  }

  ~AudioTap() override { track_->RemoveSink(this); }

  void OnData(const void *audio_data, int bits_per_sample, int sample_rate,
              size_t number_of_channels, size_t number_of_frames) override {
    const size_t n = number_of_frames * number_of_channels;
    double sq = 0;
    if (bits_per_sample == 16) {
      const int16_t *s = static_cast<const int16_t *>(audio_data);
      for (size_t i = 0; i < n; ++i) sq += double(s[i]) * s[i];
    }
    std::lock_guard<std::mutex> guard(lock_);
    Inc("callbacks");
    counters_["sampleRate"] = sample_rate;
    counters_["channels"] = static_cast<int64_t>(number_of_channels);
    counters_["framesPerChunk"] = static_cast<int64_t>(number_of_frames);
    counters_["bitsPerSample"] = bits_per_sample;
    sum_squares_ += sq;
    samples_ += n;
    if (deliver_) {
      const size_t bytes = n * bits_per_sample / 8;
      if (pcm_.size() + bytes > kMaxPcmBytes) {
        Inc("droppedToDart");
      } else {
        const uint8_t *p = static_cast<const uint8_t *>(audio_data);
        pcm_.insert(pcm_.end(), p, p + bytes);
      }
    }
  }

  EncodableMap Drain() override {
    std::lock_guard<std::mutex> guard(lock_);
    EncodableMap counters = Counters();
    counters[EncodableValue("rms")] =
        samples_ == 0 ? EncodableValue()
                      : EncodableValue(std::sqrt(sum_squares_ / samples_) / 32768.0);
    sum_squares_ = 0;
    samples_ = 0;
    EncodableMap out{
        {EncodableValue("id"), EncodableValue(id_)},
        {EncodableValue("kind"), EncodableValue(kind_)},
        {EncodableValue("counters"), EncodableValue(std::move(counters))},
    };
    if (!pcm_.empty()) {
      out[EncodableValue("pcm")] = EncodableValue(std::move(pcm_));
      pcm_.clear();
    }
    return out;
  }

 private:
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track_;
  const bool deliver_;
  double sum_squares_ = 0;
  size_t samples_ = 0;
  std::vector<uint8_t> pcm_;
};

void MediaTapsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "media_taps",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<MediaTapsPlugin>();
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

MediaTapsPlugin::MediaTapsPlugin() {}

MediaTapsPlugin::~MediaTapsPlugin() {}

void MediaTapsPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto *args = std::get_if<EncodableMap>(call.arguments());
  if (call.method_name() == "poll") {
    EncodableList list;
    for (auto &[id, tap] : taps_) list.push_back(EncodableValue(tap->Drain()));
    result->Success(EncodableValue(std::move(list)));
    return;
  }
  if (!args) {
    result->Error("media_taps", "missing arguments");
    return;
  }
  if (call.method_name() == "detach") {
    if (auto *id = std::get_if<int>(Arg(*args, "id"))) taps_.erase(*id);
    result->Success();
    return;
  }
  if (call.method_name() != "attach") {
    result->NotImplemented();
    return;
  }
  const auto *track_id = std::get_if<std::string>(Arg(*args, "trackId"));
  const auto *kind = std::get_if<std::string>(Arg(*args, "kind"));
  const auto *convert = Arg(*args, "convertWidth");
  const auto *deliver = Arg(*args, "deliver");
  if (!track_id || !kind) {
    result->Error("media_taps", "bad arguments");
    return;
  }
  // Exported by flutter_webrtc; MediaTrackForId is virtual, so it is called
  // through the vtable without needing an exported symbol. It takes no lock:
  // call it only on the platform thread (like this handler).
  auto *webrtc = FlutterWebRTCPluginSharedInstance();
  if (!webrtc) {
    result->Error("media_taps", "flutter_webrtc is not registered");
    return;
  }
  flutter_webrtc_plugin::FlutterWebRTCBase *base = webrtc;
  auto track = base->MediaTrackForId(*track_id);
  if (!track) {
    result->Error("media_taps", "no track " + *track_id);
    return;
  }
  const int convert_width =
      convert && std::holds_alternative<int>(*convert) ? std::get<int>(*convert) : 0;
  const bool deliver_flag =
      deliver && std::holds_alternative<bool>(*deliver) && std::get<bool>(*deliver);
  const int id = next_id_++;
  if (*kind == "video") {
    taps_[id] = std::make_unique<VideoTap>(
        id,
        libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack>(
            static_cast<libwebrtc::RTCVideoTrack *>(track.get())),
        convert_width, deliver_flag);
  } else {
    taps_[id] = std::make_unique<AudioTap>(
        id,
        libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack>(
            static_cast<libwebrtc::RTCAudioTrack *>(track.get())),
        deliver_flag);
  }
  result->Success(EncodableValue(id));
}

}  // namespace media_taps
