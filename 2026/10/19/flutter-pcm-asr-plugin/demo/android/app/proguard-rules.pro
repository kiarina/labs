# onnxruntime is called from JNI by class name; R8 must not rename or strip it.
-keep class ai.onnxruntime.** { *; }
