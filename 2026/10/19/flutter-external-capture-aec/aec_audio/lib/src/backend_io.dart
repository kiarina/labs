import 'dart:typed_data';
import 'package:flutter/services.dart';
class AecAudio {
  static const _channel=MethodChannel('aec_audio');
  Future<void> configure({bool enabled=true,int delayMs=80})=>_channel.invokeMethod('configure',{'enabled':enabled,'delayMs':delayMs});
  Future<void> render(Uint8List bytes)=>_channel.invokeMethod('render',{'bytes':bytes});
  Future<Uint8List> capture(Uint8List bytes) async=>(await _channel.invokeMethod<Uint8List>('capture',{'bytes':bytes}))!;
  Future<void> stopRender()=>_channel.invokeMethod('stopRender');
  Future<Map<String,dynamic>> stats() async=>Map<String,dynamic>.from((await _channel.invokeMapMethod<String,dynamic>('stats'))!);
  Future<Uint8List> renderTrace() async=>(await _channel.invokeMethod<Uint8List>('renderTrace'))!;
  Future<void> dispose()=>_channel.invokeMethod('dispose');
}
