import UIKit
import CarPlay
import Combine

/// Builds and live-updates the CarPlay UI (Driving Task category).
///
/// Layout (template depth never exceeds 3, the Driving Task limit):
///   Tab bar (root)
///     Gauges       - CPInformationTemplate, live values, Start/Stop Live
///     Logging      - CPListTemplate, start/stop HSL and Standard loggers
///     Diagnostics  - CPListTemplate -> pushed CPInformationTemplate with codes
///     Flash        - CPInformationTemplate, READ-ONLY progress (see note)
///
/// Flashing is deliberately status-only here: choosing a file, a mode and
/// starting a write must be done on the phone, parked.
@MainActor
final class CarPlayController {
    private let interface: CPInterfaceController
    private let app = AppModel.shared
    private var cancellables = Set<AnyCancellable>()

    // Gauges
    private let gaugesTemplate: CPInformationTemplate
    // Logging
    private let loggingTemplate: CPListTemplate
    private let hslItem: CPListItem
    private let stdItem: CPListItem
    private let fileItem: CPListItem
    // Diagnostics
    private let diagTemplate: CPListTemplate
    private let diagItems: [CPListItem]
    // Flash
    private let flashTemplate: CPInformationTemplate

    private var tabBar: CPTabBarTemplate?
    private var lastDiagBusy = false

    init(interfaceController: CPInterfaceController) {
        self.interface = interfaceController

        gaugesTemplate = CPInformationTemplate(title: "Gauges", layout: .twoColumn, items: [], actions: [])
        gaugesTemplate.tabTitle = "Gauges"
        gaugesTemplate.tabImage = CarPlayController.tabImage("TabGauge", fallback: "gauge")

        hslItem = CPListItem(text: "HSL Datalogger", detailText: "", image: UIImage(named: "IconLog"))
        stdItem = CPListItem(text: "Standard Logger", detailText: "", image: UIImage(named: "IconLog"))
        fileItem = CPListItem(text: "HSL parameter file", detailText: "", image: nil)
        loggingTemplate = CPListTemplate(title: "Logging", sections: [
            CPListSection(items: [hslItem, stdItem], header: "Start / stop", sectionIndexTitle: nil),
            CPListSection(items: [fileItem], header: "Setup", sectionIndexTitle: nil),
        ])
        loggingTemplate.tabTitle = "Logging"
        loggingTemplate.tabImage = CarPlayController.tabImage("TabLog", fallback: "waveform.path.ecg")

        let diagImage = UIImage(named: "IconDiag")
        diagItems = [
            CPListItem(text: "Read engine (ECM) codes", detailText: nil, image: diagImage),
            CPListItem(text: "Read transmission (TCM) codes", detailText: nil, image: diagImage),
            CPListItem(text: "Clear engine (ECM) codes", detailText: nil, image: nil),
            CPListItem(text: "Clear transmission (TCM) codes", detailText: nil, image: nil),
        ]
        diagTemplate = CPListTemplate(title: "Diagnostics", sections: [
            CPListSection(items: Array(diagItems[0...1]), header: "Read", sectionIndexTitle: nil),
            CPListSection(items: Array(diagItems[2...3]), header: "Clear", sectionIndexTitle: nil),
        ])
        diagTemplate.tabTitle = "Diag"
        diagTemplate.tabImage = CarPlayController.tabImage("TabDiag", fallback: "wrench.and.screwdriver")

        flashTemplate = CPInformationTemplate(title: "Flash", layout: .twoColumn, items: [], actions: [])
        flashTemplate.tabTitle = "Flash"
        flashTemplate.tabImage = CarPlayController.tabImage("TabFlash", fallback: "bolt.fill")
    }

    // MARK: Lifecycle

    func start() {
        wireHandlers()
        refresh()

        let tabs = CPTabBarTemplate(templates: [gaugesTemplate, loggingTemplate, diagTemplate, flashTemplate])
        tabBar = tabs
        interface.setRootTemplate(tabs, animated: false, completion: nil)

        // Any session change (gauge values, logger counters, flash progress,
        // connection state) lands here. Throttled: the HSL/gauge loops publish
        // many times a second and the car display shouldn't be rebuilt that often.
        app.objectWillChange
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        tabBar = nil
    }

    private static func tabImage(_ name: String, fallback: String) -> UIImage {
        let img = UIImage(named: name) ?? UIImage(systemName: fallback) ?? UIImage()
        return img.withRenderingMode(.alwaysTemplate)
    }

    // MARK: Refresh

    private func refresh() {
        refreshGauges()
        refreshLogging()
        refreshDiagnostics()
        refreshFlash()
    }

    private var notConnected: Bool {
        !(app.isConnectedReady || app.demoModeActive || app.hslLogger.isRunning || app.hslLogger.isStarting)
    }

    // MARK: Gauges

    private func refreshGauges() {
        if notConnected {
            gaugesTemplate.items = [CPInformationItem(title: "Not connected", detail: "Connect to your ECU on the iPhone")]
            gaugesTemplate.actions = []
            return
        }
        let session = app.session
        var items: [CPInformationItem] = []
        for slot in session.slots where slot.selectedEntry != nil {
            items.append(CPInformationItem(title: slot.gaugeLabel, detail: Self.valueText(slot)))
        }
        if items.isEmpty {
            items = [CPInformationItem(title: "No gauges", detail: "Pick gauges on the iPhone")]
        }
        gaugesTemplate.items = items

        let hslBusy = session.isHslActive
        let title: String
        if hslBusy { title = "Logger in use" }
        else { title = session.isLive ? "Stop Live" : "Start Live" }
        let button = CPTextButton(title: title, textStyle: session.isLive ? .cancel : .confirm) { [weak self] _ in
            Task { @MainActor in self?.toggleLive() }
        }
        gaugesTemplate.actions = [button]
    }

    private static func valueText(_ slot: GaugeSlot) -> String {
        guard slot.numericValue.isFinite else { return "--" }
        let v = slot.numericValue
        let number = abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return slot.gaugeUnit.isEmpty ? number : "\(number) \(slot.gaugeUnit)"
    }

    private func toggleLive() {
        let session = app.session
        guard !session.isHslActive else {
            showAlert("A logger or diagnostics session is using the ECU. Stop it first.")
            return
        }
        if session.isLive { session.stopLive() } else { session.startLive() }
        refresh()
    }

    // MARK: Logging

    private func refreshLogging() {
        let hsl = app.hslLogger
        let std = app.didLogger

        if notConnected {
            hslItem.setDetailText("Not connected")
            stdItem.setDetailText("Not connected")
        } else {
            hslItem.setText(hsl.isRunning ? "Stop HSL Datalogger" : "Start HSL Datalogger")
            if hsl.isStarting { hslItem.setDetailText("Starting…") }
            else if hsl.isRunning { hslItem.setDetailText("\(hsl.sampleCount) samples • \(Self.clock(hsl.duration))") }
            else if hsl.selectedFile == nil { hslItem.setDetailText("Choose a parameter file first") }
            else if let err = hsl.lastError { hslItem.setDetailText(err) }
            else { hslItem.setDetailText("\(hsl.selectedPids.count) channels ready") }

            stdItem.setText(std.isRunning ? "Stop Standard Logger" : "Start Standard Logger")
            if std.isStarting { stdItem.setDetailText("Starting…") }
            else if std.isRunning { stdItem.setDetailText("\(std.sampleCount) samples • \(Self.clock(std.duration))") }
            else if let err = std.lastError { stdItem.setDetailText(err) }
            else { stdItem.setDetailText("\(std.selectedEntries.count) channels ready") }
        }
        fileItem.setDetailText(hsl.selectedFile?.displayName ?? "None selected")
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggleHsl() {
        let hsl = app.hslLogger
        if hsl.isRunning || hsl.isStarting {
            hsl.stop()
            app.session.endHslLogging(resumeLive: false)
            refresh()
            return
        }
        guard let transport = app.activeTransport, !app.demoModeActive else {
            showAlert("Connect to the ECU on the iPhone first. Logging isn't available in demo mode.")
            return
        }
        guard !app.didLogger.isRunning, !app.didLogger.isStarting else {
            showAlert("Stop the Standard Logger first.")
            return
        }
        guard !app.diagnostics.isBusy, !app.flashSession.isRunning else {
            showAlert("The ECU is busy with diagnostics or a flash.")
            return
        }
        guard hsl.selectedFile != nil else {
            showAlert("Choose the HSL parameter file that matches your ECU software on the iPhone (Logging > HSL Datalogger). The wrong file reads the wrong memory.")
            return
        }
        // Same sequence LoggingMenuView + DatalogView use: take ownership
        // BEFORE attaching/starting so live polling can't race the logger.
        app.session.beginHslLogging()
        hsl.attach(transport: transport)
        hsl.start()
        refresh()
    }

    private func toggleStandard() {
        let std = app.didLogger
        if std.isRunning || std.isStarting {
            std.stop()
            app.session.endHslLogging(resumeLive: false)
            refresh()
            return
        }
        guard let transport = app.activeTransport, !app.demoModeActive else {
            showAlert("Connect to the ECU on the iPhone first. Logging isn't available in demo mode.")
            return
        }
        guard !app.hslLogger.isRunning, !app.hslLogger.isStarting else {
            showAlert("Stop the HSL Datalogger first.")
            return
        }
        guard !app.diagnostics.isBusy, !app.flashSession.isRunning else {
            showAlert("The ECU is busy with diagnostics or a flash.")
            return
        }
        app.session.beginHslLogging()
        std.attach(transport: transport)
        std.start()
        refresh()
    }

    // MARK: Diagnostics

    private func refreshDiagnostics() {
        let diag = app.diagnostics
        let busy = diag.isBusy
        let modules: [DiagModule] = [.ecm, .tcm]
        for (i, module) in modules.enumerated() {
            var readDetail: String
            if notConnected || app.demoModeActive { readDetail = "Not connected" }
            else if case .reading(let m) = diag.phase, m == module { readDetail = "Reading…" }
            else if let r = diag.results[module] { readDetail = "\(r.dtcs.count) code(s) • tap to re-read" }
            else { readDetail = "Tap to read" }
            diagItems[i].setDetailText(readDetail)

            var clearDetail = "Erases stored codes"
            if case .clearing(let m) = diag.phase, m == module { clearDetail = "Clearing…" }
            diagItems[i + 2].setDetailText(clearDetail)
        }
        if busy != lastDiagBusy { lastDiagBusy = busy }
    }

    private func readCodes(_ module: DiagModule) {
        guard let transport = app.activeTransport, !app.demoModeActive else {
            showAlert("Connect to the ECU on the iPhone first.")
            return
        }
        guard !app.hslLogger.isRunning, !app.didLogger.isRunning, !app.flashSession.isRunning else {
            showAlert("Stop logging (or wait for the flash) before reading codes.")
            return
        }
        let diag = app.diagnostics
        guard !diag.isBusy else { return }
        // Same ownership lock DiagnosticsView takes on appear.
        app.session.beginHslLogging()
        diag.attach(transport: transport)
        Task { @MainActor in
            await diag.read(module)
            app.session.endHslLogging(resumeLive: false)
            self.showCodes(for: module)
        }
    }

    private func showCodes(for module: DiagModule) {
        let diag = app.diagnostics
        var items: [CPInformationItem] = []
        if let result = diag.results[module] {
            if result.dtcs.isEmpty {
                items.append(CPInformationItem(title: "No fault codes", detail: module.shortName))
            } else {
                let limit = 8
                for dtc in result.dtcs.prefix(limit) {
                    let code = dtc.info.displayCode ?? dtc.rawHex
                    let name = dtc.info.name ?? "No description"
                    items.append(CPInformationItem(title: code, detail: name))
                }
                if result.dtcs.count > limit {
                    items.append(CPInformationItem(title: "+\(result.dtcs.count - limit) more", detail: "See the iPhone"))
                }
            }
        } else if let error = diag.errorMessage {
            items.append(CPInformationItem(title: "Couldn't read \(module.shortName)", detail: error))
        } else {
            items.append(CPInformationItem(title: module.shortName, detail: "No result"))
        }
        let template = CPInformationTemplate(title: "\(module.shortName) fault codes", layout: .leading, items: items, actions: [])
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    private func confirmClear(_ module: DiagModule) {
        guard app.activeTransport != nil, !app.demoModeActive else {
            showAlert("Connect to the ECU on the iPhone first.")
            return
        }
        guard !app.hslLogger.isRunning, !app.didLogger.isRunning, !app.flashSession.isRunning else {
            showAlert("Stop logging (or wait for the flash) before clearing codes.")
            return
        }
        let clear = CPAlertAction(title: "Clear \(module.shortName) Codes", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.interface.dismissTemplate(animated: true, completion: nil)
                self?.runClear(module)
            }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.interface.dismissTemplate(animated: true, completion: nil) }
        }
        let alert = CPAlertTemplate(
            titleVariants: [
                "Erase stored codes, freeze-frame data and reset readiness monitors? Faults still present will return.",
                "Erase stored \(module.shortName) codes?",
            ],
            actions: [clear, cancel])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    private func runClear(_ module: DiagModule) {
        guard let transport = app.activeTransport else { return }
        let diag = app.diagnostics
        guard !diag.isBusy else { return }
        app.session.beginHslLogging()
        diag.attach(transport: transport)
        Task { @MainActor in
            await diag.clear(module)
            app.session.endHslLogging(resumeLive: false)
            self.showCodes(for: module)
        }
    }

    // MARK: Flash (read-only)

    private func refreshFlash() {
        let flash = app.flashSession
        var items: [CPInformationItem] = []
        if flash.isRunning {
            items.append(CPInformationItem(title: "Status", detail: "FLASHING - \(flash.currentProgress)%"))
            if !flash.currentStep.isEmpty { items.append(CPInformationItem(title: "Step", detail: flash.currentStep)) }
            if !flash.currentStatus.isEmpty { items.append(CPInformationItem(title: "Detail", detail: flash.currentStatus)) }
            items.append(CPInformationItem(title: "Do not", detail: "Turn off ignition or disconnect"))
        } else if let error = flash.finalError {
            items.append(CPInformationItem(title: "Status", detail: "FAILED"))
            items.append(CPInformationItem(title: "Error", detail: error))
        } else if flash.isDone {
            items.append(CPInformationItem(title: "Status", detail: "Done"))
            items.append(CPInformationItem(title: "Next", detail: "Cycle ignition, check Flash Mode"))
        } else {
            items.append(CPInformationItem(title: "Status", detail: "Idle"))
            items.append(CPInformationItem(title: "Start a flash", detail: "On the iPhone, parked"))
        }
        if let name = flash.selectedFileName {
            items.append(CPInformationItem(title: "File", detail: name))
        }
        items.append(CPInformationItem(title: "Mode", detail: flash.flashMode.rawValue))
        flashTemplate.items = items
        flashTemplate.actions = []
    }

    // MARK: Handlers & alerts

    private func wireHandlers() {
        hslItem.handler = { [weak self] _, completion in
            Task { @MainActor in self?.toggleHsl() }
            completion()
        }
        stdItem.handler = { [weak self] _, completion in
            Task { @MainActor in self?.toggleStandard() }
            completion()
        }
        fileItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.showAlert("Choose or import the parameter file on the iPhone: Logging > HSL Datalogger.")
            }
            completion()
        }
        let modules: [DiagModule] = [.ecm, .tcm]
        for (i, module) in modules.enumerated() {
            diagItems[i].handler = { [weak self] _, completion in
                Task { @MainActor in self?.readCodes(module) }
                completion()
            }
            diagItems[i + 2].handler = { [weak self] _, completion in
                Task { @MainActor in self?.confirmClear(module) }
                completion()
            }
        }
    }

    private func showAlert(_ message: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in self?.interface.dismissTemplate(animated: true, completion: nil) }
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }
}
