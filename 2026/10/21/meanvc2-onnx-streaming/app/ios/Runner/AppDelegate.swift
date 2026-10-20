import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UIDevice.current.isBatteryMonitoringEnabled = true
    // Keep the screen on during the soak: an auto-locked device suspends the app.
    UIApplication.shared.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LabDevice")!
    let channel = FlutterMethodChannel(name: "lab/device", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "status" else { return result(FlutterMethodNotImplemented) }
      let d = UIDevice.current
      result([
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,  // 0 nominal .. 3 critical
        "batteryLevel": d.batteryLevel,
        "batteryState": d.batteryState.rawValue,  // 1 unplugged, 2 charging, 3 full
        "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "model": d.model,
      ])
    }
  }
}
