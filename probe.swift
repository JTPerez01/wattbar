// probe.swift — dump the full IOPowerSources description to see what the
// instant layer actually exposes.
import Foundation
import IOKit.ps

let info = IOPSCopyPowerSourcesInfo()!.takeRetainedValue()
let list = IOPSCopyPowerSourcesList(info)!.takeRetainedValue() as! [CFTypeRef]
for src in list {
    let d = IOPSGetPowerSourceDescription(info, src)!.takeUnretainedValue() as! [String: Any]
    for (k, v) in d.sorted(by: { $0.key < $1.key }) {
        print("\(k) = \(v)")
    }
    print("---")
}
