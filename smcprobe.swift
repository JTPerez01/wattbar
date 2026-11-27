// smcprobe.swift — enumerate AppleSMC keys via selector 1, dumping raw
// output bytes to discover the real struct layout on Apple Silicon.
//
// Build: xcrun swiftc -swift-version 5 -O smcprobe.swift -o smcprobe

import Foundation
import IOKit

let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0 else { print("no AppleSMC service"); exit(1) }
var conn: io_connect_t = 0
let open = IOServiceOpen(service, mach_task_self_, 0, &conn)
guard open == KERN_SUCCESS else { print("IOServiceOpen failed: \(open)"); exit(1) }
defer { IOServiceClose(conn) }

func raw(_ selector: UInt32, _ input: [UInt8]) -> (ret: Int, out: [UInt8], outCnt: Int) {
    var inputBuf = input + [UInt8](repeating: 0, count: 80 - input.count)
    var output = [UInt8](repeating: 0, count: 80)
    var outCnt = 80
    let ret = IOConnectCallStructMethod(conn, selector, &inputBuf, 80, &output, &outCnt)
    return (Int(ret), output, outCnt)
}

// selector 1 = kSMCGetKeyFromIndex: input key field = index. Try index 0
// with the key bytes at offset 0, both endians, and dump the whole reply.
for endian in [0, 1] {
    var input = [UInt8](repeating: 0, count: 80)
    if endian == 0 {
        input[0] = 0; input[1] = 0; input[2] = 0; input[3] = 0   // LE index 0
    } else {
        input[0] = 0; input[1] = 0; input[2] = 0; input[3] = 0   // BE index 0 (same for 0)
    }
    let r = raw(1, input)
    print("sel1 idx=0 endian=\(endian) ret=\(r.ret) outCnt=\(r.outCnt)")
    var line = ""
    for (i, b) in r.out.enumerated() {
        line += String(format: "%02x ", b)
        if (i + 1) % 16 == 0 { print(String(format: "%3d-%-3d ", i - 15, i) + line); line = "" }
    }
    if !line.isEmpty { print(String(format: "%3d-%-3d ", 72, 79) + line) }
    let ascii = r.out.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }.map(String.init).joined()
    print("ascii: \(ascii)\n")
}

// Now walk the index space and extract 4-char keys wherever they appear.
var found: [String] = []
var emptyRun = 0
var idx = 0
while emptyRun < 20 && idx < 4096 {
    var input = [UInt8](repeating: 0, count: 80)
    input[0] = UInt8(idx & 0xFF); input[1] = UInt8((idx >> 8) & 0xFF)
    input[2] = UInt8((idx >> 16) & 0xFF); input[3] = UInt8((idx >> 24) & 0xFF)
    let r = raw(1, input)
    let ascii = String(r.out.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }.map(String.init).joined())
    // find runs of exactly 4 printable chars surrounded by dots
    var keys: [String] = []
    var run = ""
    for c in ascii {
        if c != "." { run.append(c) } else { if run.count == 4 { keys.append(run) }; run = "" }
    }
    if run.count == 4 { keys.append(run) }
    if keys.isEmpty { emptyRun += 1 } else { emptyRun = 0 }
    for k in keys where !found.contains(k) { found.append(k) }
    idx += 1
}
print("\nunique 4-char keys found (\(found.count)):")
print(found.sorted().joined(separator: " "))
