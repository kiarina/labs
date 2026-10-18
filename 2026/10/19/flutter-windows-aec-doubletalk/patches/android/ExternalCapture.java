package com.cloudwebrtc.webrtc;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.locks.LockSupport;
import org.webrtc.*;
import org.webrtc.audio.JavaAudioDeviceModule;
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack;
import com.cloudwebrtc.webrtc.video.LocalVideoTrack;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Lab-only external capture. One shared ADM input; bounded PCM queue. */
final class ExternalCapture implements MethodChannel.MethodCallHandler,
    JavaAudioDeviceModule.AudioBufferCallback {
  private final MethodCallHandlerImpl owner;
  private final byte[] pcm = new byte[48000 / 5 * 2]; // at most 200 ms
  private int head, size;
  private long nextAudio;
  private VideoSource video;
  private AudioSource audio;
  private MediaStream stream;
  private AudioTrack audioTrack;
  private VideoTrack videoTrack;
  private String streamId, audioId, videoId;
  ExternalCapture(MethodCallHandlerImpl owner) { this.owner = owner; }

  @Override public long onBuffer(ByteBuffer buffer, int format,
      int channels, int rate, int bytesRead, long timestamp) {
    // Without AudioRecord the SDK callback is unpaced. Keep the ADM at 10 ms.
    long now = System.nanoTime();
    if (nextAudio > now) LockSupport.parkNanos(nextAudio - now);
    now = System.nanoTime();
    nextAudio = Math.max(nextAudio + 10000000L, now);
    buffer.clear();
    synchronized (this) {
    for (int i = 0; i < buffer.capacity(); i++) {
      byte b = 0;
      if (size > 0) { b = pcm[head]; head = (head + 1) % pcm.length; size--; }
      buffer.put(b);
    }
    }
    buffer.rewind();
    return now;
  }

  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "create": {
          if (streamId != null) throw new IllegalStateException("Only one external stream is supported");
          PeerConnectionFactory factory = owner.getPeerConnectionFactory();
          if (factory == null) throw new IllegalStateException("Initialize flutter_webrtc first");
          streamId = UUID.randomUUID().toString();
          audioId = UUID.randomUUID().toString(); videoId = UUID.randomUUID().toString();
          stream = factory.createLocalMediaStream(streamId);
          video = factory.createVideoSource(false);
          video.getCapturerObserver().onCapturerStarted(true);
          MediaConstraints rawConstraints = new MediaConstraints();
          for (String key : new String[]{"googEchoCancellation", "googNoiseSuppression", "googAutoGainControl", "googHighpassFilter"}) {
            rawConstraints.mandatory.add(new MediaConstraints.KeyValuePair(key, "false"));
          }
          audio = factory.createAudioSource(rawConstraints);
          AudioTrack at = factory.createAudioTrack(audioId, audio);
          VideoTrack vt = factory.createVideoTrack(videoId, video);
          audioTrack = at; videoTrack = vt;
          stream.addTrack(at); stream.addTrack(vt);
          owner.putLocalStream(streamId, stream);
          owner.putLocalTrack(audioId, new LocalAudioTrack(at));
          owner.putLocalTrack(videoId, new LocalVideoTrack(vt));
          Map<String, Object> response = new HashMap<>();
          response.put("streamId", streamId); response.put("audioTrackId", audioId);
          response.put("videoTrackId", videoId); result.success(response); return;
        }
        case "pushAudio": {
          byte[] bytes = call.argument("bytes");
          if (bytes == null || bytes.length % 2 != 0) throw new IllegalArgumentException("PCM16 bytes required");
          synchronized (this) {
            if (streamId == null) { result.success(null); return; }
            for (byte b : bytes) {
              if (size == pcm.length) { head = (head + 1) % pcm.length; size--; }
              pcm[(head + size) % pcm.length] = b; size++;
            }
          }
          result.success(null); return;
        }
        case "pushVideo": {
          if (video == null) { result.success(null); return; }
          byte[] bytes = call.argument("bytes");
          int w = ((Number)call.argument("width")).intValue();
          int h = ((Number)call.argument("height")).intValue();
          if (w <= 0 || h <= 0 || bytes.length != w * h * 4) throw new IllegalArgumentException("Packed BGRA required");
          JavaI420Buffer frame = JavaI420Buffer.allocate(w, h);
          ByteBuffer y = frame.getDataY(), u = frame.getDataU(), v = frame.getDataV();
          for (int row = 0; row < h; row++) for (int col = 0; col < w; col++) {
            int i = (row * w + col) * 4;
            int b = bytes[i] & 255, g = bytes[i+1] & 255, r = bytes[i+2] & 255;
            y.put(row * frame.getStrideY() + col, (byte)clip(((66*r+129*g+25*b+128)>>8)+16));
            if ((row & 1) == 0 && (col & 1) == 0) {
              // Average the available 2x2 chroma block, including odd edges.
              int rr=0,gg=0,bb=0,n=0;
              for(int dy=0;dy<2 && row+dy<h;dy++) for(int dx=0;dx<2 && col+dx<w;dx++) {
                int k=((row+dy)*w+col+dx)*4;
                bb+=bytes[k]&255;gg+=bytes[k+1]&255;rr+=bytes[k+2]&255;n++;
              }
              rr/=n;gg/=n;bb/=n;
              u.put(row/2*frame.getStrideU()+col/2,(byte)clip(((-38*rr-74*gg+112*bb+128)>>8)+128));
              v.put(row/2*frame.getStrideV()+col/2,(byte)clip(((112*rr-94*gg-18*bb+128)>>8)+128));
            }
          }
          long ts = ((Number)call.argument("timestampUs")).longValue() * 1000;
          VideoFrame vf = new VideoFrame(frame, 0, ts);
          video.getCapturerObserver().onFrameCaptured(vf); vf.release();
          result.success(null); return;
        }
        case "flush": {
          synchronized (this) { size=0; head=0; }
          result.success(null); return;
        }
        case "dispose": {
          if (streamId != null) owner.streamDispose(streamId);
          if (video != null) video.getCapturerObserver().onCapturerStopped();
          if (audioTrack != null) audioTrack.dispose();
          if (videoTrack != null) videoTrack.dispose();
          if (stream != null) stream.dispose();
          if (video != null) video.dispose(); if (audio != null) audio.dispose();
          audioTrack=null; videoTrack=null; stream=null;
          video=null; audio=null; streamId=null;
          synchronized(this) { size=0; head=0; }
          result.success(null); return;
        }
        default: result.notImplemented();
      }
    } catch (Exception error) { result.error("external_capture", error.toString(), null); }
  }
  private static int clip(int n) { return Math.max(0, Math.min(255, n)); }
}
