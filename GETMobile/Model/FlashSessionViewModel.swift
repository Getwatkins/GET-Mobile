import Foundation

enum FlashMode: String, CaseIterable, Identifiable {
    case unlockFlash = "Unlock + Flash"
    case normalFlash = "Normal Flash"
    case calOnlyFlash = "CAL-Only Flash"
    case stockRelock = "Flash Stock / Re-Lock"
    var id: String { rawValue }

    /// Mirrors the desktop app exactly (Simos18FlashingControl:
    /// `ShouldPatchCboot = flashMode == 0 || flashMode == 1`): Unlock and Normal
    /// flashes MUST write a patched CBOOT. If a full flash writes the file's
    /// unpatched CBOOT while the tune's ASW/CAL are modified, the bootloader
    /// rejects them and the ECU stays stuck in flash mode after the reset.
    /// Stock Relock deliberately does NOT patch (that is what re-locks the ECU),
    /// and CAL-only never touches CBOOT.
    var patchesCboot: Bool {
        switch self {
        case .unlockFlash, .normalFlash: return true
        case .calOnlyFlash, .stockRelock: return false
        }
    }

    var cbootStatus: String {
        switch self {
        case .unlockFlash, .normalFlash: return "CBOOT: patched automatically (ECU stays unlocked)."
        case .calOnlyFlash: return "CBOOT: not touched."
        case .stockRelock: return "CBOOT: NOT patched - the ECU is re-locked to stock."
        }
    }

    var explanation: String {
        switch self {
        case .unlockFlash:
            return "First-time unlock on a factory ECU. Requires the untouched factory .bin matching this ECU's exact box code (not a tune) - it gets patched to perform the unlock, then all 5 blocks are written with a patched CBOOT."
        case .normalFlash:
            return "Writes all 5 blocks (CBOOT is patched automatically). Use this for a full tune flash on an ECU that's already been unlocked."
        case .calOnlyFlash:
            return "Writes only the CAL block - much faster. Requires the file's CAL to match the ECU's currently installed box code exactly (checked automatically before writing anything)."
        case .stockRelock:
            return "Writes all 5 blocks from the unmodified factory .bin and re-locks the ECU (CBOOT is NOT patched). Any tune on the ECU is removed."
        }
    }
}

enum FlashTarget: String, CaseIterable, Identifiable {
    case ecm = "Engine (ECM)"
    case tcm = "Transmission (TCM)"
    var id: String { rawValue }
}

@MainActor
final class FlashSessionViewModel: ObservableObject {
    /// Switching target/TCM type throws away any loaded file: a file
    /// validated for one module must never carry over to another.
    @Published var target: FlashTarget = .ecm { didSet { if oldValue != target { clearLoadedFile() } } }
    @Published var dsgModuleType: DsgModuleType = .dq250 { didSet { if oldValue != dsgModuleType { clearLoadedFile() } } }
    @Published private(set) var loadedTcmBytes: [UInt8]?
    @Published private(set) var tcmFileSummary: String = ""

    @Published var moduleType: Simos18ModuleType = .simos18_1
    @Published var flashMode: FlashMode = .normalFlash
    /// Derived from the Flash Mode (same rule as the desktop app) - no longer a
    /// manual toggle, because a wrong value silently leaves the ECU in flash mode.
    var shouldPatchCboot: Bool { flashMode.patchesCboot }

    @Published var selectedFileName: String?
    @Published private(set) var loadedBlocks: [Int: [UInt8]]?
    @Published private(set) var loadWarnings: [String] = []

    @Published private(set) var isRunning = false
    @Published private(set) var isDone = false
    @Published private(set) var currentStep = ""
    @Published private(set) var currentStatus = ""
    @Published private(set) var currentProgress = 0
    @Published private(set) var logLines: [String] = []
    @Published private(set) var finalError: String?

    private var flashTask: Task<Void, Never>?

    private func clearLoadedFile() {
        selectedFileName = nil
        loadedBlocks = nil
        loadedTcmBytes = nil
        tcmFileSummary = ""
        loadWarnings = []
    }

    func loadFile(data: Data, fileName: String) {
        selectedFileName = fileName
        let bytes = [UInt8](data)

        if target == .tcm {
            let check = DsgFlashOrchestrator.checkFile(moduleType: dsgModuleType, bytes: bytes)
            loadWarnings = check.warnings
            loadedTcmBytes = check.ready ? bytes : nil
            tcmFileSummary = check.summary
            return
        }

        let meta: (offsets: [Int: Int], lengths: [Int: Int], versions: [Int: (start: Int, end: Int)], project: String, expectedSize: Int)
        switch moduleType {
        case .simos18_1:
            meta = (Simos18ModuleInfo.binfileOffsets, Simos18ModuleInfo.blockLengths, Simos18ModuleInfo.softwareVersionLocation, Simos18ModuleInfo.projectName, Simos18ModuleInfo.binfileSize)
        case .simos18_10:
            meta = (Simos1810ModuleInfo.binfileOffsets, Simos1810ModuleInfo.blockLengths, Simos1810ModuleInfo.softwareVersionLocation, Simos1810ModuleInfo.projectName, Simos1810ModuleInfo.binfileSize)
        }

        var warnings: [String] = []
        if bytes.count != meta.expectedSize {
            warnings.append("File is \(bytes.count) bytes, expected exactly \(meta.expectedSize) for this ECU family. Continuing anyway, but this usually means it's the wrong file or the wrong ECU family is selected.")
        }

        let (blocks, splitWarnings) = BinFileHandler.blocksFromData(
            bytes, binfileOffsets: meta.offsets, blockLengths: meta.lengths,
            softwareVersionLocation: meta.versions, projectName: meta.project)
        warnings.append(contentsOf: splitWarnings)

        loadWarnings = warnings
        loadedBlocks = blocks.count == 5 ? blocks : nil

        if blocks.count != 5 {
            warnings.append("Only recognized \(blocks.count) of 5 blocks in this file for \(meta.project) (see warnings above). Check that you selected the right ECU family and the right file.")
            loadWarnings = warnings
        }
    }

    var canStart: Bool {
        guard !isRunning else { return false }
        return target == .tcm ? loadedTcmBytes != nil : loadedBlocks != nil
    }

    func startFlash(transport: UdsTransport) {
        guard !isRunning else { return }
        let flashTarget = target
        let tcmBytes = loadedTcmBytes
        let tcmType = dsgModuleType
        if flashTarget == .tcm {
            guard tcmBytes != nil else { return }
        } else {
            guard loadedBlocks != nil else { return }
        }
        let blocks = loadedBlocks ?? [:]

        isRunning = true
        isDone = false
        finalError = nil
        logLines.removeAll()
        currentStep = ""; currentStatus = ""; currentProgress = 0
        if flashTarget == .ecm {
            appendLog("Flash mode: \(flashMode.rawValue). \(flashMode.cbootStatus)")
        }

        var options = Simos18FlashOptions(moduleType: moduleType)
        options.shouldPatchCboot = shouldPatchCboot
        switch flashMode {
        case .unlockFlash: options.frfBlocksForUnlock = blocks
        case .calOnlyFlash: options.inputBlocksForCalFlash = blocks
        // Normal and Stock Relock are the same full 5-block path and differ only
        // in shouldPatchCboot (see FlashMode.patchesCboot) - same as the desktop.
        case .normalFlash, .stockRelock: options.inputBlocksForNormalFlash = blocks
        }

        flashTask = Task { [weak self] in
            guard let self else { return }
            do {
                let statusCb: (String, String, Int) -> Void = { [weak self] step, status, progress in
                    Task { @MainActor in
                        self?.currentStep = step
                        self?.currentStatus = status
                        self?.currentProgress = progress
                    }
                }
                let logCb: (String) -> Void = { [weak self] message in
                    Task { @MainActor in
                        self?.appendLog(message)
                    }
                }
                if flashTarget == .tcm, let tcmBytes {
                    try await DsgFlashOrchestrator.runFlash(
                        transport: transport,
                        options: DsgFlashOptions(moduleType: tcmType, binFileBytes: tcmBytes),
                        statusCallback: statusCb, logDetail: logCb)
                } else {
                    try await Simos18FlashOrchestrator.runFlash(
                        transport: transport,
                        options: options,
                        statusCallback: statusCb, logDetail: logCb)
                }
                await MainActor.run {
                    self.isRunning = false
                    self.isDone = true
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRunning = false
                    self.appendLog("Cancelled by user.")
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.finalError = error.localizedDescription
                    self.appendLog("FAILED: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Requests cancellation. Honest caveat surfaced in the UI, not just
    /// here: Swift Task cancellation is cooperative and only takes effect
    /// between awaits - it cannot interrupt a write that's already in
    /// flight on the wire, and it cannot undo a write that already
    /// completed. This stops the *next* step from starting, nothing more.
    func cancelFlash() {
        flashTask?.cancel()
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.append("[\(timestamp)] \(message)")
    }
}
