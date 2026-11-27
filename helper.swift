// helper.swift — WattBar PMU helper (runs as root via LaunchDaemon).
//
// The IORegistry/PS-layer current is a slow gauge (~1 min). `pmset -g
// rawlog` streams the fuel gauge's raw packets — genuinely live
// instantaneous current (plus AC/charging/percent), emitted whenever the
// gauge polls (~10-30s idle, faster under load). This daemon parses the
// stream and writes the latest packet to /Users/Shared/wattbar-live.json,
// with a separate 3s heartbeat. The sample timestamp is only updated when
// a battery packet arrives.
//
// Build: xcrun swiftc -swift-version 5 -O helper.swift -o wattbar-pm

import Foundation

let outURL = URL(fileURLWithPath: "/Users/Shared/wattbar-live.json")

var lastA: Double = 0
var lastP: Double = 0
var lastV: Double?
var lastAC = false
var lastChg = false
var lastC: Double = 0       // last GENUINE charge rate (packet said "Charging")
var lastD: Double = 0       // last genuine drain rate (any real negative)
var lastSampledAt: TimeInterval?
var lastDrainSampledAt: TimeInterval?

func writeLive() {
    guard let lastSampledAt else { return }
    var d: [String: Any] = [
        "t": Int(Date().timeIntervalSince1970), // heartbeat, including for older apps
        "s": lastSampledAt,
        "a": lastA,            // mA, signed: + charging, - draining
        "p": lastP,            // percent
        "ac": lastAC ? 1 : 0,  // AC state reported in the gauge packet
        "chg": lastChg ? 1 : 0
    ]
    if lastC > 0 { d["c"] = lastC }   // plug-intent magnitude for the app
    if lastD > 0 { d["d"] = lastD }
    if let lastDrainSampledAt { d["dt"] = lastDrainSampledAt }
    if let lastV { d["v"] = lastV }   // mV, only if the gauge ever reports it
    if let json = try? JSONSerialization.data(withJSONObject: d) {
        try? json.write(to: outURL, options: .atomic)
    }
}

/// Parse one rawlog battery line, e.g.
///   " No AC; Not Charging; 59%; Cap=59: FCC=100; Design=8579; Time=5:48; -1130mA; Cycles=4/1000; Location=0;"
func handleLine(_ line: String) {
    let parts = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let mA = parts.compactMap({ part -> Double? in
        part.hasSuffix("mA") ? Double(part.dropLast(2)) : nil
    }).first, mA.isFinite else { return }
    let sampledAt = Date().timeIntervalSince1970
    lastA = mA
    lastSampledAt = sampledAt
    if let pct = parts.compactMap({ part -> Double? in
        part.hasSuffix("%") ? Double(part.dropLast(1)) : nil
    }).first { lastP = pct }
    if let v = parts.compactMap({ part -> Double? in
        part.hasSuffix("mV") ? Double(part.dropLast(2)) : nil
    }).first { lastV = v }
    if let ac = parts.first {
        lastAC = ac == "AC" || (ac.contains("AC") && !ac.hasPrefix("No"))
    }
    lastChg = parts.contains { $0 == "Charging" }
    if lastChg, lastA > 0 { lastC = lastA }   // only genuine charge packets — stale positives (right after unplug) don't count
    if !lastAC, lastA < -50 {
        lastD = -lastA
        lastDrainSampledAt = sampledAt
    }
    writeLive()
}

// Restore history with its original age. c and d still support older apps.
if let data = try? Data(contentsOf: outURL),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let c = json["c"] as? Double, c > 0 { lastC = c }
    if let d = json["d"] as? Double, d > 0 {
        lastD = d
        lastDrainSampledAt = json["dt"] as? TimeInterval
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
p.arguments = ["-g", "rawlog"]
let out = Pipe()
p.standardOutput = out
do { try p.run() } catch { exit(1) }

// Parse lines on a serial queue so the heartbeat timer and the stream
// handler never race on the shared state.
let q = DispatchQueue(label: "wattbar-pm")
var buffer = Data()
out.fileHandleForReading.readabilityHandler = { h in
    let chunk = h.availableData
    if chunk.isEmpty { exit(0) }   // stream ended: KeepAlive restarts us
    q.sync {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            handleLine(String(decoding: buffer[..<nl], as: UTF8.self))
            buffer.removeSubrange(...nl)
        }
    }
}

// The heartbeat keeps the liveness check satisfied during quiet gauge periods.
Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
    q.sync { writeLive() }
}

RunLoop.main.run()
