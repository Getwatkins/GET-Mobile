import Foundation
import CoreLocation
import Combine
import UIKit

enum PerfSourceKind: String, CaseIterable, Identifiable {
    case gps = "GPS"
    case vehicle = "Vehicle speed (OBD)"
    var id: String { rawValue }
}

struct PerfRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var source: String
    var rollout: Bool
    var results: PerfResults
}

/// Feeds speed samples from CoreLocation. iPhone GPS reports speed from the
/// Doppler shift at about 1 Hz - much better than differencing positions, but
/// still one sample per second. All callbacks arrive on the main thread.
final class GPSSpeedProvider: NSObject, CLLocationManagerDelegate {
    var onSample: ((PerfSample, _ hAcc: Double, _ speedAcc: Double) -> Void)?
    var onAuth: ((CLAuthorizationStatus) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }
    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuth?(manager.authorizationStatus)
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            guard loc.horizontalAccuracy >= 0, loc.speed >= 0, loc.speedAccuracy >= 0 else { continue }
            // Ignore cached fixes from before updates started.
            guard abs(loc.timestamp.timeIntervalSinceNow) < 3 else { continue }
            onSample?(PerfSample(t: loc.timestamp.timeIntervalSinceReferenceDate, v: loc.speed),
                      loc.horizontalAccuracy, loc.speedAccuracy)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Owns the speed source, the trackers and the saved history.
@MainActor
final class PerformanceSession: ObservableObject {
    // Live state
    @Published private(set) var running = false
    @Published private(set) var speedMph: Double = 0
    @Published private(set) var liveG: Double = 0
    @Published private(set) var phase: LaunchTracker.Phase = .waiting
    @Published private(set) var results = PerfResults()
    @Published private(set) var rolling = false
    @Published private(set) var rollingStartTime: Double?
    @Published private(set) var lastRolling: Double?
    @Published private(set) var bestRolling: Double?
    @Published private(set) var launchTime: Double?      // reference time for live ET (seconds, reference-date clock)
    @Published private(set) var sampleRate: Double = 0   // Hz
    /// Errors / warnings only (nil = all good). The normal state text is derived from `phase` in the view.
    @Published private(set) var notice: String?
    @Published private(set) var gpsAccuracyM: Double?
    @Published private(set) var gpsSpeedAccMps: Double?
    @Published private(set) var history: [PerfRecord] = []
    @Published private(set) var trace: [PerfSample] = [] // last run's speed trace for the chart

    @Published var source: PerfSourceKind = .gps {
        didSet { if oldValue != source, running { stop(); start() } }
    }
    @Published var rollout = true {
        didSet { launch.rollout = rollout }
    }

    private var launch = LaunchTracker()
    private var rollingTracker = RollingTracker()
    private let gps = GPSSpeedProvider()
    private var recent: [PerfSample] = []
    private var rateWindow: [Double] = []
    private var pollTask: Task<Void, Never>?
    private var ownsEcu = false
    private let historyKey = "perf.history.v1"

    init() {
        loadHistory()
        gps.onSample = { [weak self] s, h, a in
            Task { @MainActor in self?.gpsSample(s, hAcc: h, speedAcc: a) }
        }
        gps.onAuth = { [weak self] st in
            Task { @MainActor in self?.authChanged(st) }
        }
    }

    // MARK: Control

    func start() {
        guard !running else { return }
        resetTrackers()
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on
        notice = nil
        switch source {
        case .gps:
            if gps.status == .denied || gps.status == .restricted {
                notice = "Location access is off. Enable it in Settings > GET Mobile > Location."
            }
            gps.start()
        case .vehicle:
            startVehicle()
        }
    }

    func stop() {
        guard running else { return }
        gps.stop()
        pollTask?.cancel(); pollTask = nil
        releaseEcu()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .waiting
        notice = nil
    }

    /// Clears the current run (keeps history) and re-arms.
    func resetRun() {
        let wasRunning = running
        resetTrackers()
        results = PerfResults(); trace = []; lastRolling = nil; launchTime = nil
        _ = wasRunning
    }

    func clearHistory() {
        history = []; bestRolling = nil
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func resetTrackers() {
        launch = LaunchTracker(); launch.rollout = rollout
        rollingTracker.reset()
        recent = []; rateWindow = []
        rolling = false; rollingStartTime = nil; phase = .waiting; sampleRate = 0
    }

    // MARK: Sources

    private func authChanged(_ st: CLAuthorizationStatus) {
        guard running, source == .gps else { return }
        if st == .denied || st == .restricted {
            notice = "Location access is off. Enable it in Settings > GET Mobile > Location."
        }
    }

    private func gpsSample(_ s: PerfSample, hAcc: Double, speedAcc: Double) {
        guard running, source == .gps else { return }
        gpsAccuracyM = hAcc
        gpsSpeedAccMps = speedAcc
        // A fix with a poor speed estimate would corrupt a timed run.
        guard speedAcc <= 3.0 else {
            notice = "GPS signal is weak (±\(Int(hAcc)) m). Move to open sky."
            return
        }
        notice = nil
        ingest(s)
    }

    private func startVehicle() {
        let app = AppModel.shared
        guard let transport = app.activeTransport, !app.demoModeActive, app.isConnectedReady else {
            notice = "Connect to the ECU first to use vehicle speed."
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        guard !app.hslLogger.isRunning, !app.didLogger.isRunning, !app.flashSession.isRunning, !app.diagnostics.isBusy else {
            notice = "Another ECU session is running. Stop it first."
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        guard let entry = CommonDidCatalog.all.first(where: { $0.name == "Vehicle Speed" }) else {
            notice = "Vehicle Speed channel not found in the catalog."
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        // Take exclusive ownership of the ECU link, same as the loggers do.
        app.session.beginHslLogging()
        ownsEcu = true
        notice = nil
        let uds = UdsClient(transport: transport)
        uds.requestTimeoutSeconds = 1
        pollTask = Task { [weak self] in
            await transport.abandonPendingOperation()
            var failures = 0
            while !Task.isCancelled {
                let sent = Date().timeIntervalSinceReferenceDate
                do {
                    let data = try await uds.readDataByIdentifier(entry.did)
                    let recv = Date().timeIntervalSinceReferenceDate
                    let kmh = DidValueDecoder.decode(entry, from: data).numeric
                    failures = 0
                    if kmh.isFinite {
                        await MainActor.run { self?.notice = nil }
                        // Timestamp at the midpoint of the round trip.
                        let sample = PerfSample(t: (sent + recv) / 2, v: max(0, kmh) / 3.6)
                        await MainActor.run { self?.ingest(sample) }
                    }
                } catch {
                    failures += 1
                    if failures >= 5 {
                        await MainActor.run { self?.notice = "Vehicle speed read failed: \(error.localizedDescription)" }
                        failures = 0
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
        }
    }

    private func releaseEcu() {
        if ownsEcu {
            AppModel.shared.session.endHslLogging(resumeLive: false)
            ownsEcu = false
        }
    }

    // MARK: Ingest

    private func ingest(_ s: PerfSample) {
        speedMph = s.v / PerfConst.mph

        // Update rate (Hz) over the last ~2 s.
        rateWindow.append(s.t)
        rateWindow.removeAll { s.t - $0 > 2 }
        if rateWindow.count >= 2, let f = rateWindow.first, s.t > f {
            sampleRate = Double(rateWindow.count - 1) / (s.t - f)
        }

        // Live acceleration from a >= 0.3 s slope.
        recent.append(s)
        recent.removeAll { s.t - $0.t > 3 }
        if let ref = recent.last(where: { s.t - $0.t >= 0.3 }) ?? recent.first, s.t > ref.t {
            liveG = ((s.v - ref.v) / (s.t - ref.t)) / PerfConst.g
        }

        // Rolling 60-130
        if let t = rollingTracker.ingest(s) {
            lastRolling = t
            results.sixtyTo130 = t
            if bestRolling == nil || t < bestRolling! { bestRolling = t }
            saveRecord(PerfResults(zeroTo60: nil, sixtyTo130: t, marks: [], peakG: 0, topSpeedMph: speedMph))
        }
        rolling = rollingTracker.isTiming
        rollingStartTime = rollingTracker.startT

        // Standing start
        let event = launch.ingest(s)
        phase = launch.phase
        switch event {
        case .started:
            trace = []
            results = launch.results
            results.sixtyTo130 = lastRolling
            launchTime = launch.tRef
        case .finished(let res):
            results = res
            results.sixtyTo130 = lastRolling
            launchTime = nil
            saveRecord(res)
        case .discarded:
            launchTime = nil
            results = launch.results
        case .none:
            if launch.phase == .running {
                results = launch.results
                results.sixtyTo130 = lastRolling
                launchTime = launch.tRef
                trace.append(s)
            }
        }
    }

    // MARK: History

    private func saveRecord(_ r: PerfResults) {
        guard !r.isEmpty else { return }
        history.insert(PerfRecord(date: Date(), source: source.rawValue, rollout: rollout, results: r), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let h = try? JSONDecoder().decode([PerfRecord].self, from: data) else { return }
        history = h
        bestRolling = h.compactMap { $0.results.sixtyTo130 }.min()
    }

    // MARK: Bests

    var best060: Double? { history.compactMap { $0.results.zeroTo60 }.min() }
    func bestMark(_ feet: Double) -> DragMark? {
        history.compactMap { $0.results.mark(feet) }.min { $0.et < $1.et }
    }
}
