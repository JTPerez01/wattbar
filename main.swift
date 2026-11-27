// WattBar shows battery power in the menu bar. Open its menu for reading source and age.
// Build: xcrun swiftc -swift-version 5 -O main.swift -o wattbar
// Read once: ./wattbar --once
// Poll interval: --interval N (seconds, default 2)

import AppKit
import IOKit
import IOKit.ps

struct PSState {
    let onAC: Bool
    let current: Double?      // mA, signed
    let percent: Double?
}

func readPowerSource() -> PSState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let type = desc[kIOPSTypeKey as String] as? String,
              type == (kIOPSInternalBatteryType as String) else { continue }
        guard let state = desc[kIOPSPowerSourceStateKey as String] as? String else { continue }
        return PSState(
            onAC: state == (kIOPSACPowerValue as String),
            current: (desc["Current"] as? NSNumber)?.doubleValue,
            percent: (desc["Current Capacity"] as? NSNumber)?.doubleValue
        )
    }
    return nil
}

struct LivePacket: Decodable {
    let heartbeatAt: TimeInterval
    let sampledAt: TimeInterval?
    let milliamps: Double
    let millivolts: Double?
    let percent: Double?
    let ac: Int?
    let drainMA: Double?
    let drainSampledAt: TimeInterval?

    var onAC: Bool? { ac.map { $0 == 1 } }

    enum CodingKeys: String, CodingKey {
        // The original helper writes t alone. Its packets have unknown sample age.
        case heartbeatAt = "t", sampledAt = "s"
        case milliamps = "a", millivolts = "v", percent = "p", ac
        case drainMA = "d", drainSampledAt = "dt"
    }

    func isAlive(at now: TimeInterval) -> Bool {
        (-5...10).contains(now - heartbeatAt)
    }

    func sampleAge(at now: TimeInterval) -> TimeInterval? {
        sampledAt.map { max(now - $0, 0) }
    }

    func hasUsableSample(at now: TimeInterval) -> Bool {
        guard isAlive(at: now) else { return false }
        // Some fuel-gauge polls take about a minute. Allow for that cadence.
        return sampledAt.map { (-5...90).contains(now - $0) } ?? true
    }
}

struct BatteryCurrent {
    enum Source {
        case fuelGauge(age: TimeInterval?)
        case system
        case estimate(age: TimeInterval)
    }

    let milliamps: Double
    let source: Source

    var estimated: Bool {
        if case .estimate = source { return true }
        return false
    }

    var detail: String {
        switch source {
        case .fuelGauge(let age):
            guard let age else { return "Fuel gauge · sample age unavailable" }
            return "Fuel gauge · sampled \(Int(age))s ago"
        case .system:
            return "System battery reading · sample age unavailable"
        case .estimate(let age):
            return "Estimated from battery drain \(Int(age))s ago"
        }
    }

    static func resolve(onAC: Bool, live: LivePacket?, systemMA: Double?, now: TimeInterval) -> Self? {
        if let live, live.hasUsableSample(at: now),
           live.onAC == nil || live.onAC == onAC, onAC || live.milliamps <= 50 {
            return Self(milliamps: live.milliamps, source: .fuelGauge(age: live.sampleAge(at: now)))
        }
        if let systemMA, onAC || systemMA <= 50 {
            return Self(milliamps: systemMA, source: .system)
        }

        // A positive reading after unplug is stale. Only a recent, previously
        // observed battery drain rate is suitable as an estimate.
        guard !onAC, let live, live.isAlive(at: now),
              let drain = live.drainMA, drain > 50,
              let drainSampledAt = live.drainSampledAt,
              (-5...120).contains(now - drainSampledAt)
        else { return nil }
        return Self(milliamps: -drain, source: .estimate(age: max(now - drainSampledAt, 0)))
    }
}

struct Reading {
    let millivolts: Double
    let current: BatteryCurrent?
    let percent: Double
    let cycles: Int
    let onAC: Bool

    enum State { case charging, discharging, idle, unavailable }

    var state: State {
        guard let current else { return .unavailable }
        if current.milliamps > 50 { return .charging }
        // An AC adapter can supply the Mac while the battery reports a small
        // negative current. Reserve the drain indicator for meaningful assist.
        if current.milliamps < (onAC ? -700 : -50) { return .discharging }
        return .idle
    }

    var watts: Double? {
        guard let current else { return nil }
        if state == .idle { return 0 }
        return abs(current.milliamps * millivolts) / 1_000_000
    }

    var statusText: String {
        guard let watts else { return "—" }
        switch state {
        case .charging: return String(format: "↑%.1f", watts)
        case .discharging: return String(format: current?.estimated == true ? "↓~%.1f" : "↓%.1f", watts)
        case .idle: return "≈0.0"
        case .unavailable: return "—"
        }
    }

    var detailText: String {
        let power = onAC ? "AC power" : "on battery"
        var details: [String] = []
        if let watts, let current {
            details.append(String(format: current.estimated ? "~%.2f W" : "%.2f W", watts))
            details.append(String(format: "%+.0f mA", current.milliamps))
        }
        details += [String(format: "%.0f%%", percent), "\(cycles) cycles",
                    String(format: "%.3f V", millivolts / 1000), power,
                    current?.detail ?? "Waiting for a battery current reading"]
        return details.joined(separator: "   ·   ")
    }
}

private let liveURL = URL(fileURLWithPath: "/Users/Shared/wattbar-live.json")

func readBattery(powerSource ps: PSState? = readPowerSource()) -> Reading? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var propsUnmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
    else { return nil }

    func num(_ key: String) -> Double? { (props[key] as? NSNumber)?.doubleValue }

    let now = Date().timeIntervalSince1970
    let packet = (try? Data(contentsOf: liveURL)).flatMap { try? JSONDecoder().decode(LivePacket.self, from: $0) }
    let live = packet.flatMap { $0.hasUsableSample(at: now) ? $0 : nil }
    // macOS power-source notifications can arrive before the next gauge packet.
    let onAC = ps?.onAC ?? live?.onAC ?? (props["ExternalConnected"] as? NSNumber)?.boolValue ?? false
    let gaugeMatchesPower = live?.onAC == nil || live?.onAC == onAC
    let gaugeVoltage = gaugeMatchesPower ? live?.millivolts : nil
    guard let voltage = gaugeVoltage ?? num("Voltage"), voltage > 0 else { return nil }
    let current = BatteryCurrent.resolve(onAC: onAC, live: packet,
                                         systemMA: ps?.current ?? num("Amperage"), now: now)

    let battData = props["BatteryData"] as? [String: Any]
    let percent = live?.percent
        ?? ps?.percent
        ?? (battData?["StateOfCharge"] as? NSNumber)?.doubleValue
        ?? num("StateOfCharge") ?? 0

    return Reading(millivolts: voltage, current: current, percent: percent,
                   cycles: (props["CycleCount"] as? NSNumber)?.intValue ?? 0, onAC: onAC)
}

// MARK: - Menu bar app

final class WattApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var detailItem: NSMenuItem?
    private var powerSource: CFRunLoopSource?
    private var pendingSample: DispatchWorkItem?
    private var lastTickAC: Bool?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval) { self.pollInterval = pollInterval }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.attributedTitle = Self.title("…", color: .secondaryLabelColor)

        let menu = NSMenu()
        menu.delegate = self
        let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem = detail
        menu.addItem(detail)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit WattBar", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        startTimer()
        setupPowerNotifications()
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func setupPowerNotifications() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let app = Unmanaged<WattApp>.fromOpaque(ctx).takeUnretainedValue()
            app.powerChanged()
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Power event: give the charger a 1s beat to settle, then sample.
    private func powerChanged() {
        sample(afterDelay: 1.0)
    }

    /// Samples once (optionally after a transition delay). Coalesces flaps.
    private func sample(afterDelay delay: TimeInterval) {
        pendingSample?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        pendingSample = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startTimer() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Cheap instant-layer check: hold the sample 1s across a
            // transition so the first number is settled data.
            let ps = readPowerSource()
            if let ps {
                if let prev = self.lastTickAC, ps.onAC != prev {
                    self.lastTickAC = ps.onAC
                    self.sample(afterDelay: 1.0)
                    return
                }
            }
            self.refresh(powerSource: ps)
        }
        t.tolerance = max(pollInterval / 4, 0.5)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        refresh()
    }

    private func refresh(powerSource ps: PSState? = readPowerSource()) {
        if let ps { lastTickAC = ps.onAC }
        if let reading = readBattery(powerSource: ps) {
            apply(reading)
        } else {
            statusItem?.button?.attributedTitle = Self.title("—", color: .secondaryLabelColor)
            detailItem?.title = "Battery readings unavailable"
        }
    }

    private func apply(_ r: Reading) {
        let color: NSColor
        switch r.state {
        case .charging: color = .systemGreen
        case .discharging: color = .systemOrange
        case .idle, .unavailable: color = .secondaryLabelColor
        }
        statusItem?.button?.attributedTitle = Self.title(r.statusText, color: color)
        detailItem?.title = r.detailText
    }

    private static func title(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ])
    }
}

// MARK: - Entry point

#if WATTBAR_TEST
runWattBarTests()
#else
var pollInterval: TimeInterval = 2.0
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--interval"), i + 1 < args.count {
    pollInterval = max(TimeInterval(args[i + 1]) ?? pollInterval, 0.5)
}

if args.contains("--once") || args.contains("--dump") {
    if let r = readBattery() {
        print("\(r.statusText)  (\(r.detailText))")
    } else {
        print("wattbar: no battery reading available")
    }
    exit(0)
}

// Module-level strong reference: NSApplication.delegate is not retained.
let delegate = WattApp(pollInterval: pollInterval)
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon, no Cmd-Tab
app.run()
#endif
