package com.kiarina.labs.aec_audio;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioRecordingConfiguration;
import java.util.ArrayList;
import java.util.List;
import android.content.Context;
import android.app.KeyguardManager;
import android.os.Build;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;

/** Speaker output + independent DSP. This plugin never constructs AudioRecord. */
public final class AecAudioPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  static { System.loadLibrary("aec_audio_android"); }
  private MethodChannel channel;
  private AudioTrack speaker;
  private AudioManager manager;
  private KeyguardManager keyguard;
  private int previousMode;
  private boolean routeOwned;
  private long engine;
  private int delayMs;
  private long renderBytes, captureBytes, outputBytes;
  private int sampleRate;
  private final java.util.ArrayDeque<byte[]> renderQueue=new java.util.ArrayDeque<>();
  private int queuedBytes;
  private volatile boolean stopping;
  private Thread writer;
  private volatile String writerError;
  private volatile long speakerWrittenBytes, speakerSilenceBytes;
  private final java.io.ByteArrayOutputStream renderTrace=new java.io.ByteArrayOutputStream();
  private boolean traceTruncated;
  private void writeLoop() {
    android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
    try {
      while(!stopping) {
        byte[] block=new byte[960];
        synchronized(renderQueue) {
          if(!renderQueue.isEmpty()) {block=renderQueue.removeFirst();queuedBytes-=block.length;}
          else speakerSilenceBytes+=block.length;
        }
        int offset=0;
        while(offset<block.length&&!stopping) {
          int count=speaker.write(block,offset,block.length-offset,AudioTrack.WRITE_BLOCKING);
          if(count<=0) {if(stopping)return;throw new IllegalStateException("AudioTrack.write="+count);}
          reverse(engine,java.util.Arrays.copyOfRange(block,offset,offset+count));
          synchronized(renderTrace) {
            if(renderTrace.size()+count<=48000*2*120)renderTrace.write(block,offset,count);
            else traceTruncated=true;
          }
          offset+=count;speakerWrittenBytes+=count;
        }
      }
    } catch(Exception error) {writerError=error.toString();}
  }
  private native long create(boolean enabled);
  private native void destroy(long handle);
  private native void reverse(long handle, byte[] pcm);
  private native byte[] capture(long handle, byte[] pcm, int delay);
  private native void reset(long handle);

  @Override public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
    manager=(AudioManager)binding.getApplicationContext().getSystemService(Context.AUDIO_SERVICE);
    keyguard=(KeyguardManager)binding.getApplicationContext().getSystemService(Context.KEYGUARD_SERVICE);
    // Background queue serializes capture and render without blocking Flutter UI.
    channel = new MethodChannel(binding.getBinaryMessenger(), "aec_audio",
        io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
        binding.getBinaryMessenger().makeBackgroundTaskQueue());
    channel.setMethodCallHandler(this);
  }
  @Override public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null); dispose();
  }
  private void dispose() {
    stopping=true;
    if(speaker!=null) speaker.pause();
    if(writer!=null) {try{writer.join(2000);if(writer.isAlive())throw new IllegalStateException("Speaker thread did not terminate");}catch(InterruptedException error){Thread.currentThread().interrupt();}writer=null;}
    synchronized(renderQueue){renderQueue.clear();queuedBytes=0;}
    if (speaker != null) { speaker.pause(); speaker.flush(); speaker.release(); speaker=null; }
    if (engine != 0) { destroy(engine); engine=0; }
    if(routeOwned) {
      if(Build.VERSION.SDK_INT>=31) manager.clearCommunicationDevice();
      else manager.setSpeakerphoneOn(false);
      manager.setMode(previousMode);routeOwned=false;
    }
  }
  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    try {
      switch(call.method) {
        case "configure": {
          dispose();
          Boolean enabled=call.argument("enabled"); Number delay=call.argument("delayMs");
          delayMs=delay==null?0:delay.intValue();
          previousMode=manager.getMode();routeOwned=true;
          manager.setMode(AudioManager.MODE_IN_COMMUNICATION);
          if(Build.VERSION.SDK_INT>=31) {
            boolean selected=false;
            for(AudioDeviceInfo device:manager.getAvailableCommunicationDevices())
              if(device.getType()==AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                selected=manager.setCommunicationDevice(device);
            if(!selected)throw new IllegalStateException("Cannot select built-in speaker");
          } else manager.setSpeakerphoneOn(true);
          engine=create(Boolean.TRUE.equals(enabled));
          if(engine==0)throw new IllegalStateException("AEC create failed");
          int minimum=AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_MONO,AudioFormat.ENCODING_PCM_16BIT);
          speaker=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder()
              .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
              .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
              .setAudioFormat(new AudioFormat.Builder().setSampleRate(48000)
                  .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
              .setBufferSizeInBytes(Math.max(minimum,960*4)).setTransferMode(AudioTrack.MODE_STREAM).build();
          if(speaker.getState()!=AudioTrack.STATE_INITIALIZED)throw new IllegalStateException("AudioTrack init failed");
          sampleRate=speaker.getSampleRate(); speaker.play();
          renderBytes=0;captureBytes=0;outputBytes=0;speakerWrittenBytes=0;speakerSilenceBytes=0;
          synchronized(renderTrace){renderTrace.reset();traceTruncated=false;}
          stopping=false;writerError=null;writer=new Thread(this::writeLoop,"aec-speaker");writer.start();
          result.success(null);return;
        }
        case "render": {
          requireEngine(); byte[] bytes=call.argument("bytes");requirePcm(bytes);
          if(writerError!=null)throw new IllegalStateException(writerError);
          synchronized(renderQueue) {
            if(queuedBytes+bytes.length>19200)throw new IllegalStateException("Speaker queue exceeds 200 ms");
            for(int offset=0;offset<bytes.length;offset+=960) {
              byte[] chunk=java.util.Arrays.copyOfRange(bytes,offset,Math.min(bytes.length,offset+960));
              renderQueue.addLast(chunk);queuedBytes+=chunk.length;
            }
          }
          renderBytes+=bytes.length;
          result.success(null);return;
        }
        case "capture": {
          requireEngine();byte[] bytes=call.argument("bytes");requirePcm(bytes);
          byte[] output=capture(engine,bytes,delayMs);captureBytes+=bytes.length;outputBytes+=output.length;
          result.success(output);return;
        }
        case "stopRender": {
          synchronized(renderQueue) {renderQueue.clear();queuedBytes=0;}
          // Bound OFF tail by the hardware buffer; flushing a concurrently writing
          // AudioTrack is unsafe. The queue contains at most 200 ms of PCM.
          result.success(null);return;
        }
        case "reset": {requireEngine();reset(engine);result.success(null);return;}
        case "renderTrace": {synchronized(renderTrace){result.success(renderTrace.toByteArray());}return;}
        case "stats": {
          Map<String,Object> stats=new HashMap<>();stats.put("renderBytes",renderBytes);
          stats.put("captureBytes",captureBytes);stats.put("outputBytes",outputBytes);
          stats.put("speakerWrittenBytes",speakerWrittenBytes);stats.put("speakerSilenceBytes",speakerSilenceBytes);
          synchronized(renderQueue) {stats.put("queuedSpeakerBytes",queuedBytes);}
          stats.put("writerError",writerError);
          synchronized(renderTrace){stats.put("renderTraceTruncated",traceTruncated);}
          stats.put("speakerSampleRate",sampleRate);stats.put("delayMs",delayMs);
          stats.put("keyguardLocked",keyguard.isKeyguardLocked());
          stats.put("deviceLocked",keyguard.isDeviceLocked());
          stats.put("supportsUnprocessedSource",manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
          stats.put("voiceCallVolume",manager.getStreamVolume(AudioManager.STREAM_VOICE_CALL));
          stats.put("voiceCallVolumeMax",manager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL));
          if(speaker!=null) {
            stats.put("playbackHeadFrames",Integer.toUnsignedLong(speaker.getPlaybackHeadPosition()));
            if(Build.VERSION.SDK_INT>=24) stats.put("speakerUnderruns",speaker.getUnderrunCount());
          }
          if(Build.VERSION.SDK_INT>=24) {
            List<Map<String,Object>> active=new ArrayList<>();
            for(AudioRecordingConfiguration config:manager.getActiveRecordingConfigurations()) {
              Map<String,Object> entry=new HashMap<>();
              entry.put("sessionId",config.getClientAudioSessionId());
              entry.put("source",config.getClientAudioSource());
              entry.put("clientSampleRate",config.getClientFormat().getSampleRate());
              entry.put("deviceSampleRate",config.getFormat().getSampleRate());
              AudioDeviceInfo inputDevice=config.getAudioDevice();
              entry.put("inputDeviceType",inputDevice==null?-1:inputDevice.getType());
              if(Build.VERSION.SDK_INT>=29) entry.put("silenced",config.isClientSilenced());
              active.add(entry);
            }
            stats.put("activeRecordingConfigurations",active);
          }
          if(Build.VERSION.SDK_INT>=31) {
            AudioDeviceInfo route=manager.getCommunicationDevice();
            stats.put("speakerDeviceType",route==null?-1:route.getType());
          }
          stats.put("captureBackend","record owns microphone; this plugin only opens AudioTrack");
          result.success(stats);return;
        }
        case "dispose":dispose();result.success(null);return;
        default:result.notImplemented();
      }
    }catch(Exception error){result.error("aec_audio",error.toString(),null);}
  }
  private void requireEngine(){if(engine==0)throw new IllegalStateException("configure first");}
  private static void requirePcm(byte[] bytes){if(bytes==null||bytes.length%2!=0)throw new IllegalArgumentException("PCM16 even bytes required");}
}
