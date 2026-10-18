# Local macOS probe

Copied from flutter_onnxruntime 1.9.0 (MIT). The only initial behavioral addition is the `memoryProbe` method, which reports native session and value dictionary counts under the existing lock. The inference and disposal paths are unchanged. This experiment does not edit the global package cache or publish a fork.
