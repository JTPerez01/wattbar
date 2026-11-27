// Regressions for the shipping WattBar display and packet-selection logic.
// xcrun swiftc -swift-version 5 -D WATTBAR_TEST main.swift simtest.swift -o simtest
// ./simtest

import Foundation

func runWattBarTests() {
    let now: TimeInterval = 1_000

    func packet(_ json: String) -> LivePacket {
        try! JSONDecoder().decode(LivePacket.self, from: Data(json.utf8))
    }

    func reading(onAC: Bool, live: LivePacket?, systemMA: Double? = nil) -> Reading {
        Reading(millivolts: 12_700,
                current: BatteryCurrent.resolve(onAC: onAC, live: live, systemMA: systemMA, now: now),
                percent: 100, cycles: 24, onAC: onAC)
    }

    let full = reading(onAC: true, live: packet(#"{"t":999,"s":980,"a":0,"ac":1}"#))
    precondition(full.state == .idle && full.statusText == "≈0.0", "A full battery at zero current is idle")
    precondition(full.detailText.contains("sampled 20s ago"), "Sample age comes from the sample timestamp")

    let assist = reading(onAC: true, live: packet(#"{"t":1000,"s":999,"a":-4000,"ac":1,"chg":1,"c":3479}"#))
    precondition(assist.statusText == "↓50.8", "Battery assist remains negative despite stale charging metadata")

    let beforeUnplug = packet(#"{"t":1000,"s":995,"a":3479,"ac":1,"c":3479}"#)
    let unplugged = reading(onAC: false, live: beforeUnplug, systemMA: 3479)
    precondition(unplugged.state == .unavailable && unplugged.statusText == "—",
                 "A stale charge reading cannot be repurposed as measured drain")
    let unpluggedWithSystemDrain = reading(onAC: false, live: beforeUnplug, systemMA: -400)
    precondition(unpluggedWithSystemDrain.statusText == "↓5.1" &&
                 unpluggedWithSystemDrain.detailText.contains("System battery reading"),
                 "Use a compatible reading from the system when the gauge still reports AC")

    let estimatePacket = packet(#"{"t":1000,"s":996,"a":3479,"ac":0,"d":420,"dt":945}"#)
    let estimated = reading(onAC: false, live: estimatePacket)
    precondition(estimated.statusText == "↓~5.3" &&
                 estimated.detailText.contains("Estimated from battery drain 55s ago"),
                 "A recent drain estimate is marked and uses the cached drain age")
    precondition(reading(onAC: false, live: estimatePacket, systemMA: -400).statusText == "↓5.1",
                 "A compatible system reading takes precedence over a cached estimate")
    let expiredDrain = packet(#"{"t":1000,"s":996,"a":3479,"ac":0,"d":420,"dt":800}"#)
    precondition(reading(onAC: false, live: expiredDrain).state == .unavailable,
                 "An old estimate expires even when the helper is alive")

    let quiet = packet(#"{"t":1000,"s":940,"a":-500,"ac":0}"#)
    precondition(reading(onAC: false, live: quiet).detailText.contains("sampled 60s ago"),
                 "A normal idle gap does not discard the gauge reading")
    let stale = packet(#"{"t":1000,"s":900,"a":-8000,"ac":0}"#)
    let fallback = reading(onAC: false, live: stale, systemMA: -400)
    precondition(stale.isAlive(at: now) && fallback.statusText == "↓5.1" &&
                 fallback.detailText.contains("sample age unavailable"),
                 "A new heartbeat does not refresh an old sample")
    let stopped = packet(#"{"t":980,"s":980,"a":-500,"ac":0}"#)
    precondition(reading(onAC: false, live: stopped).state == .unavailable,
                 "A missing heartbeat expires the helper reading")

    let legacy = packet(#"{"t":1000,"a":-500,"ac":0,"d":500}"#)
    let legacyReading = reading(onAC: false, live: legacy)
    precondition(legacyReading.statusText == "↓6.3" &&
                 legacyReading.detailText.contains("Fuel gauge · sample age unavailable"),
                 "Older helpers still work without claiming a sample age")

    print("WattBar display and packet regression tests passed.")
}
