import Foundation

/// Pure timing math for the Performance feature (no UI, no CoreLocation), so it
/// can be reasoned about and unit-tested on its own.
///
/// Everything works on a stream of (time, speed) samples. Distance is never
/// taken from GPS positions: it is integrated from speed, which is far less
/// noisy (GPS speed is a Doppler measurement). Between two samples we assume
/// constant acceleration, so speed is linear and distance is quadratic - that
/// lets us solve exactly *when* inside a sample interval a speed or distance
/// mark was crossed instead of rounding to the sample time. This matters most
/// for a 1 Hz iPhone GPS, where one interval is a full second.
enum PerfConst {
    static let mph = 0.44704      // metres/second per mph
    static let ft = 0.3048        // metres per foot
    static let g = 9.80665
    static let trapFeet = 66.0    // strip trap speed = average over the last 66 ft
    /// Distance marks reported for drag-strip mode, in feet.
    static let dragMarks: [Double] = [60, 330, 660, 1320]
}

struct PerfSample {
    var t: Double   // seconds (any consistent clock)
    var v: Double   // metres/second
}

struct DragMark: Codable, Equatable {
    var feet: Double
    var et: Double          // seconds
    var speedMph: Double    // trap speed (66 ft average) for 1/8 and 1/4, instantaneous for 60 and 330 ft
    var isTrap: Bool
}

struct PerfResults: Codable, Equatable {
    var zeroTo60: Double?
    var sixtyTo130: Double?
    var marks: [DragMark] = []
    var peakG: Double = 0
    var topSpeedMph: Double = 0

    func mark(_ feet: Double) -> DragMark? { marks.first { $0.feet == feet } }
    var isEmpty: Bool { zeroTo60 == nil && sixtyTo130 == nil && marks.isEmpty }
}

enum PerfMath {
    /// Analyse one standing-start run. `s[0]` is the last stationary sample,
    /// `s[1...]` are the moving samples after it.
    static func analyzeLaunch(_ s: [PerfSample], rollout: Bool) -> (results: PerfResults, t0: Double, tRef: Double)? {
        guard s.count >= 2, s[1].t > s[0].t, s[1].v > 0 else { return nil }
        let tp = s[0].t, v0 = max(0, s[0].v)
        let t1 = s[1].t, v1 = s[1].v

        // Estimate the true launch instant t0 (somewhere in [tp, t1]).
        var t0 = tp
        let dtp = t1 - tp
        if s.count >= 3, dtp > 0.25 {
            // Slow source (GPS ~1 Hz): launch accel is unobservable, so use the
            // acceleration of the next interval as a proxy.
            let dt2 = s[2].t - t1
            let a2 = dt2 > 0 ? (s[2].v - v1) / dt2 : 0
            if a2 > 0.3 { t0 = min(t1 - 0.001, max(tp, t1 - v1 / a2)) }
        } else if v1 > v0 {
            // Fast source: line through the last stationary and first moving
            // sample, intersected with zero speed.
            t0 = max(tp, t1 - v1 * dtp / (v1 - v0))
        }

        // Path points: launch (t0, v=0, d=0) then every sample.
        var ts: [Double] = [t0], vs: [Double] = [0], ds: [Double] = [0]
        for i in 1..<s.count {
            guard s[i].t > ts.last! else { continue }
            let dt = s[i].t - ts.last!
            ds.append(ds.last! + dt * (vs.last! + s[i].v) / 2)
            ts.append(s[i].t)
            vs.append(s[i].v)
        }
        guard ts.count >= 2 else { return nil }

        func atDistance(_ D: Double) -> (t: Double, v: Double)? {
            guard D > 0 else { return (ts[0], 0) }
            for i in 1..<ts.count where ds[i] >= D && ds[i - 1] < D {
                let dt = ts[i] - ts[i - 1]
                let a = (vs[i] - vs[i - 1]) / dt
                let rem = D - ds[i - 1]
                let va = vs[i - 1]
                var tau: Double
                if abs(a) < 1e-6 {
                    guard va > 0 else { return nil }
                    tau = rem / va
                } else {
                    let disc = va * va + 2 * a * rem
                    guard disc >= 0 else { return nil }
                    tau = (-va + disc.squareRoot()) / a
                }
                tau = min(max(tau, 0), dt)
                return (ts[i - 1] + tau, va + a * tau)
            }
            return nil
        }
        func atSpeed(_ V: Double) -> Double? {
            for i in 1..<ts.count where vs[i - 1] < V && vs[i] >= V {
                let f = (V - vs[i - 1]) / (vs[i] - vs[i - 1])
                return ts[i - 1] + f * (ts[i] - ts[i - 1])
            }
            return nil
        }

        // ET reference: launch, or the moment the car has rolled 1 ft (the
        // drag-strip "rollout" that timing systems don't count).
        var tRef = t0
        if rollout, let r = atDistance(1 * PerfConst.ft) { tRef = r.t }

        var res = PerfResults()
        if let t60 = atSpeed(60 * PerfConst.mph) { res.zeroTo60 = t60 - tRef }
        for feet in PerfConst.dragMarks {
            guard let end = atDistance(feet * PerfConst.ft) else { continue }
            let et = end.t - tRef
            if feet >= 660, let start = atDistance((feet - PerfConst.trapFeet) * PerfConst.ft), end.t > start.t {
                let trap = (PerfConst.trapFeet * PerfConst.ft) / (end.t - start.t)
                res.marks.append(DragMark(feet: feet, et: et, speedMph: trap / PerfConst.mph, isTrap: true))
            } else {
                res.marks.append(DragMark(feet: feet, et: et, speedMph: end.v / PerfConst.mph, isTrap: false))
            }
        }
        res.topSpeedMph = (vs.max() ?? 0) / PerfConst.mph

        // Peak acceleration from slopes over >= 0.25 s windows (a single
        // 50 ms step of a noisy source would otherwise read absurd g).
        var peak = 0.0
        for i in 1..<ts.count {
            var j = i - 1
            while j > 0, ts[i] - ts[j] < 0.25 { j -= 1 }
            let a = (vs[i] - vs[j]) / (ts[i] - ts[j])
            peak = max(peak, a)
        }
        res.peakG = peak / PerfConst.g
        return (res, t0, tRef)
    }
}

/// Rolling 60 -> 130 mph: no standstill needed. Starts timing when speed
/// crosses 60 going up, stops at 130, cancels if speed falls back under 60.
struct RollingTracker {
    private var prev: PerfSample?
    private(set) var startT: Double?
    var lowMph = 60.0
    var highMph = 130.0

    var isTiming: Bool { startT != nil }

    /// Returns the elapsed time when a run completes on this sample.
    mutating func ingest(_ s: PerfSample) -> Double? {
        defer { prev = s }
        guard let p = prev, s.t > p.t else { return nil }
        let lo = lowMph * PerfConst.mph, hi = highMph * PerfConst.mph
        if p.v < lo, s.v >= lo {
            startT = p.t + (lo - p.v) / (s.v - p.v) * (s.t - p.t)
        } else if s.v < lo {
            startT = nil
        }
        if let st = startT, p.v < hi, s.v >= hi {
            let te = p.t + (hi - p.v) / (s.v - p.v) * (s.t - p.t)
            startT = nil
            return te - st
        }
        return nil
    }

    mutating func reset() { prev = nil; startT = nil }
}

/// Standing-start state machine: waiting -> armed -> running -> finished.
struct LaunchTracker {
    enum Phase { case waiting, armed, running, finished }
    enum Event { case none, started, finished(PerfResults), discarded }

    private(set) var phase: Phase = .waiting
    private(set) var results = PerfResults()
    private(set) var t0: Double?
    private(set) var tRef: Double?
    var rollout = true

    private var samples: [PerfSample] = []
    private var lastStationary: PerfSample?
    private var peakV = 0.0
    private var savedResults = PerfResults()

    private let stopV = 0.5 * 1.0            // m/s: below this = stopped
    private let goV = 1.0                    // m/s: above this = launched
    private let dropV = 6 * PerfConst.mph    // falling this far under peak ends the run
    private let minPeakV = 10 * PerfConst.mph

    var isRunning: Bool { phase == .running }

    mutating func reset() {
        phase = .waiting; samples = []; lastStationary = nil; peakV = 0
        t0 = nil; tRef = nil; results = PerfResults(); savedResults = PerfResults()
    }

    mutating func ingest(_ s: PerfSample) -> Event {
        switch phase {
        case .waiting:
            if s.v < stopV { phase = .armed; lastStationary = s }
        case .armed:
            if s.v <= goV {
                lastStationary = s            // stopped or creeping while staging
            } else if let st = lastStationary {
                savedResults = results
                samples = [st, s]
                peakV = s.v
                phase = .running
                update()
                return .started
            }
        case .running:
            samples.append(s)
            peakV = max(peakV, s.v)
            update()
            if s.v < stopV || s.v < peakV - dropV || (s.t - samples[0].t) > 90 {
                if peakV < minPeakV {           // false start / rolled forward
                    results = savedResults
                    phase = s.v < stopV ? .armed : .waiting
                    if phase == .armed { lastStationary = s }
                    return .discarded
                }
                phase = .finished
                return .finished(results)
            }
        case .finished:
            if s.v < stopV { phase = .armed; lastStationary = s }
        }
        return .none
    }

    private mutating func update() {
        if let r = PerfMath.analyzeLaunch(samples, rollout: rollout) {
            results = r.results; t0 = r.t0; tRef = r.tRef
        }
    }
}
