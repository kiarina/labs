// The largest window of a process (its CGWindowID), for `screencapture -l`.
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best: (Int, Double) = (0, 0)
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  let b = w[kCGWindowBounds as String] as! [String: Double]
  let area = b["Width"]! * b["Height"]!
  if area > best.1 { best = (w[kCGWindowNumber as String] as! Int, area) }
}
print(best.0)
