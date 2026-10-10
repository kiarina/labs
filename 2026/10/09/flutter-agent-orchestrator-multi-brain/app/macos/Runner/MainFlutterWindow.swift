import ApplicationServices
import Cocoa
import CoreGraphics
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Draw under a transparent title bar like the Codex desktop app; the
    // sidebar leaves room for the traffic lights.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.minSize = NSSize(width: 900, height: 560)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerPermissions(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// macOS privacy permissions of this app, for the start screen. Workers
  /// run as this app's children, so what they do (a `screencapture`, an
  /// AppleScript that clicks) asks macOS on this app's behalf; granting it
  /// here, while someone is at the screen, keeps an unattended worker from
  /// stopping at a dialog no one answers.
  private func registerPermissions(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "orchestrator/permissions", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result([
          "accessibility": AXIsProcessTrusted(),
          "screenRecording": CGPreflightScreenCaptureAccess(),
        ])
      case "requestAccessibility":
        // Shows macOS's dialog (once) that leads to System Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        result(AXIsProcessTrustedWithOptions(options))
      case "requestScreenRecording":
        // Adds this app to the list and shows macOS's dialog (once); the
        // grant takes effect after the app restarts.
        result(CGRequestScreenCaptureAccess())
      case "openSettings":
        let pane = (call.arguments as? String) ?? "Privacy"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
          NSWorkspace.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
