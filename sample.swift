// sample.swift — measure which current field actually updates in real time.
import Foundation
import IOKit
import IOKit.ps

func bms(_ key: String) -> String {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return "?" }
    defer { IOObjectRelease(s) }
    var p: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = p?.takeRetainedValue() as? [String: Any] else { return "?" }
    if let n = d[key] as? NSNumber { return "\(n)" }
    return "?"
}

func psCurrent() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "?" }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
        return "\(d["Current"] ?? "?")"
    }
    return "?"
}

let f = DateFormatter()
f.dateFormat = "HH:mm:ss"
for _ in 0..<20 {
    print("\(f.string(from: Date())) inst=\(bms("InstantAmperage")) amp=\(bms("Amperage")) ps=\(psCurrent())")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 2)
}
