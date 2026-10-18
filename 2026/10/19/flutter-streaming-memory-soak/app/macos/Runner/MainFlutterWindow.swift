import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow {
  private var probe: FlutterMethodChannel?
  private var activity: NSObjectProtocol?
  override func awakeFromNib() {
    let controller = FlutterViewController()
    let frame = self.frame
    self.contentViewController = controller
    self.setFrame(frame, display: true)
    RegisterGeneratedPlugins(registry: controller)
    probe = FlutterMethodChannel(name:"memory_soak/probe", binaryMessenger:controller.engine.binaryMessenger)
    probe?.setMethodCallHandler { call, result in
      if call.method == "beginWork" {
        if self.activity == nil {
          self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "User-requested finite media analysis experiment")
        }
        result(true); return
      }
      if call.method == "endWork" {
        if let token = self.activity { ProcessInfo.processInfo.endActivity(token); self.activity = nil }
        result(true); return
      }
      if call.method == "relieve" {
        result(Int64(malloc_zone_pressure_relief(nil, 0)))
        return
      }
      guard call.method == "snapshot" else { result(FlutterMethodNotImplemented); return }
      var stats = malloc_statistics_t()
      malloc_zone_statistics(nil, &stats)
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let code = withUnsafeMutablePointer(to:&info) { pointer in
        pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      result([
        "malloc_in_use": Int64(stats.size_in_use),
        "malloc_allocated": Int64(stats.size_allocated),
        "malloc_blocks": Int64(stats.blocks_in_use),
        "footprint": code == KERN_SUCCESS ? Int64(info.phys_footprint) : -1,
        "resident": code == KERN_SUCCESS ? Int64(info.resident_size) : -1
      ])
    }
    super.awakeFromNib()
  }
}
