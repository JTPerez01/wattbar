// Earlier WattBar transition model. The app and its regression tests use main.swift.

import Foundation

struct Reading {
    let millivolts: Double
    let milliamps: Double   // signed: + charging, - draining
    let percent: Double
    let cycles: Int
    let onAC: Bool          // from the PS layer (instant), not the BMS
    let psCharging: Bool?   // PS "Is Charging" — instant charge-state truth
    let adapterRatedWatts: Double?

    enum State { case charging, discharging, idle }

    var state: State {
        if milliamps > 50 { return .charging }
        if milliamps < -50 { return .discharging }
        return .idle
    }
    var watts: Double { abs(milliamps * millivolts) / 1_000_000 }
    var arrow: String {
        switch state {
        case .charging: return "↑"
        case .discharging: return "↓"
        case .idle: return "≈"
        }
    }
}

func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
func fmt0(_ v: Double) -> String { String(format: "%.0f", v) }

enum Kind { case charge, drain, idle }

/// Convergence-phase title. `wantAC` is the transition target from the PS
/// layer. On unplug (wantAC == false) we force ↓: the battery physically
/// cannot charge without a charger, so a positive BMS current is stale.
/// On plug-in we do NOT force: both charging and assist are possible, and
/// the sample's sign is the truth during the adapter ramp.
func transitionTitle(_ r: Reading, wantAC: Bool?) -> (String, Kind) {
    if wantAC == false {
        return ("↓" + fmt1(r.watts), .drain)
    }
    if wantAC == true, r.psCharging == true {
        // The PS layer says we're charging — show it even if the current
        // sample hasn't flipped yet (charge controller still ramping).
        return ("↑" + fmt1(r.watts), .charge)
    }
    switch r.state {
    case .charging: return ("↑" + fmt1(r.watts), .charge)
    case .discharging:
        // On AC a small negative current is stale telemetry noise around
        // the charge controller — the adapter powers the machine. Real
        // battery assist only happens under meaningful load.
        if r.watts >= (r.adapterRatedWatts ?? 60) * 0.15 {
            return ("↓" + fmt1(r.watts), .drain)
        }
        return ("≈0.0", .idle)
    case .idle: return ("≈0.0", .idle)
    }
}

/// Steady-state title. Totals are only shown when they are informative:
/// charging fast enough that the adapter must be saturated (≈ headroom),
/// or draining hard enough on AC that the adapter must be saturated
/// (≈ drain + rated). Otherwise a single number — no guesses.
func steadyTitle(_ r: Reading) -> (String, Kind) {
    var state: Reading.State = (!r.onAC && r.state == .charging) ? .discharging : r.state
    if r.onAC, r.psCharging == true, state == .discharging {
        // PS says charging; a negative current sample is stale.
        state = .charging
    }
    let drain = r.watts
    switch state {
    case .charging:
        let head = "↑" + fmt1(drain)
        if let rated = r.adapterRatedWatts, drain >= rated * 0.3 {
            return (head + "  ≈" + fmt0(max(rated - drain, 0)), .charge)
        }
        return (head, .charge)
    case .discharging:
        let head = "↓" + fmt1(drain)
        if r.onAC, let rated = r.adapterRatedWatts, drain >= rated * 0.15 {
            return (head + "  ≈" + fmt0(drain + rated), .drain)
        }
        if r.onAC {
            // Small "drain" on AC is stale noise, not real discharge —
            // the adapter powers the machine.
            return ("≈0.0", .idle)
        }
        return (head, .drain)
    case .idle:
        return ("≈0.0", .idle)
    }
}

/// Detail-line total description for the menu, matching steadyTitle.
func steadyDetail(_ r: Reading) -> String {
    let state: Reading.State = (!r.onAC && r.state == .charging) ? .discharging : r.state
    let drain = r.watts
    switch state {
    case .charging:
        if let rated = r.adapterRatedWatts, drain >= rated * 0.3 {
            return "total ≈" + fmt0(max(rated - drain, 0)) + " W (adapter " + fmt0(rated) + " W)"
        }
        return "total —"
    case .discharging:
        if !r.onAC { return "total " + fmt0(drain) + " W" }
        if let rated = r.adapterRatedWatts, drain >= rated * 0.15 {
            return "total ≈" + fmt0(drain + rated) + " W (adapter " + fmt0(rated) + " W)"
        }
        return "total —"
    case .idle:
        return r.onAC ? "total —" : "total 0 W"
    }
}

/// Transition/steady state machine, poll-driven.
///
/// AC state comes from the PS layer (instant). After a transition we enter
/// a convergence phase: single-number titles refreshed every poll until the
/// data agrees with the new reality (or a ~1 min timeout).
///
/// Steady state uses an exponential moving average rather than a sliding
/// window mean: old samples decay instead of diluting every paint, so the
/// number tracks ramps quickly. The alpha is adaptive — fast right after a
/// settle, then relaxed for smoothing.
struct WattLogic {
    enum Action: Equatable { case applyNow, none }

    private(set) var converging = false
    private(set) var currentTitle: (String, Kind)?
    private(set) var lastReading: Reading?
    private var samples: [Reading] = []
    private var wantAC: Bool?
    private var lastAC: Bool?
    private var convergePoints = 0
    private var steadyCache: (String, Kind)?
    private var emaA: Double?
    private var emaV: Double?
    private var pollsSinceSettle = 0

    let target = 3       // min points (incl. the first) before settling
    let maxPolls = 12    // give up and trust the data after ~1 min
    let alphaFast = 0.8  // EMA weight right after a transition
    let alphaSlow = 0.4  // EMA weight in settled steady state
    let fastPolls = 15   // ~30s of fast tracking after settling

    mutating func poll(_ r: Reading) -> Action {
        lastReading = r

        if lastAC == nil {
            lastAC = r.onAC
        } else if r.onAC != lastAC {
            // Transition — detected from the instant PS layer.
            lastAC = r.onAC
            wantAC = r.onAC
            converging = true
            convergePoints = 0
            samples.removeAll()
            steadyCache = nil
        }

        if converging {
            samples.append(r)
            convergePoints += 1
            let t = transitionTitle(r, wantAC: wantAC)
            currentTitle = t
            if convergePoints >= target && settledOK() {
                converging = false
                settle()
                return .applyNow
            }
            if convergePoints >= maxPolls {
                converging = false
                settle()
                return .applyNow
            }
            return .applyNow
        }

        // Steady: exponential moving average, fast then relaxed.
        pollsSinceSettle += 1
        let alpha = pollsSinceSettle <= fastPolls ? alphaFast : alphaSlow
        emaA = (emaA.map { alpha * r.milliamps + (1 - alpha) * $0 }) ?? r.milliamps
        emaV = (emaV.map { alpha * r.millivolts + (1 - alpha) * $0 }) ?? r.millivolts
        let st = steadyTitle(emaReading() ?? r)
        steadyCache = st
        currentTitle = st
        // Paint immediately during the fast-tracking window after a
        // transition so ramps show up poll-by-poll, then relax to the
        // app's regular display cadence.
        return pollsSinceSettle <= fastPolls ? .applyNow : .none
    }

    /// Can we settle? On unplug, require at least one genuinely draining
    /// sample — a positive reading is stale until proven otherwise.
    private func settledOK() -> Bool {
        if wantAC == false {
            return samples.contains { $0.state == .discharging }
        }
        // Charging expected: don't settle until a genuinely charging
        // sample exists (the current can lag the charge controller).
        if samples.last?.psCharging == true {
            return samples.contains { $0.state == .charging }
        }
        return true
    }

    private mutating func settle() {
        let base: Reading
        if wantAC == false {
            // Unplug: settle on the freshest draining sample.
            let draining = samples.filter { $0.state == .discharging }
            base = draining.last ?? samples.last!
        } else if samples.last?.psCharging == true {
            // Plug-in + charging: settle on the freshest charging sample.
            let charging = samples.filter { $0.state == .charging }
            base = charging.last ?? samples.last!
        } else {
            // Plug-in, not charging (assist): settle on the freshest sample.
            base = samples.last!
        }
        emaA = base.milliamps
        emaV = base.millivolts
        pollsSinceSettle = 0
        let st = steadyTitle(base)
        steadyCache = st
        currentTitle = st
    }

    /// The EMA-valued reading the icon and details are rendered from.
    func emaReading() -> Reading? {
        guard let ea = emaA, let ev = emaV, let last = lastReading else { return nil }
        return Reading(millivolts: ev, milliamps: ea, percent: last.percent,
                       cycles: last.cycles, onAC: last.onAC,
                       psCharging: last.psCharging,
                       adapterRatedWatts: last.adapterRatedWatts)
    }

    /// Back-compat name for the app layer.
    func avgReading() -> Reading? { emaReading() }
}
