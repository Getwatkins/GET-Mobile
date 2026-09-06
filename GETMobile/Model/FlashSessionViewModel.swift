import Foundation

enum FlashMode: String, CaseIterable, Identifiable {
    case unlockFlash = "Unlock + Flash"
    case normalFlash = "Normal Flash"
    case calOnlyFlash = "CAL-Only Flash"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .unlockFlash:
            return "First-time unlock on a factory ECU. Requires the untouched factory .bin matching this ECU's exact box code (not a tune) - it gets patched to perform the unlock, then all 5 blocks are written."
        case .normalFlash:
            return "Writes all 5 blocks. Use this for a full tune flash on an ECU that's already been unlocked."
        case .calOnlyFlash:
            return "Writes only the CAL block - much faster. Requires the file's CAL to match the ECU's currently installed box code exactly (checked automatically before writing anything)."
        }
    }
}

@MainActor
final class FlashSessionViewModel: ObservableObject {
    @Published var moduleType: Simos18ModuleType = .simos18_1
    @Published var flashMode: FlashMode = .normalFlash
    @Published var shouldPatchCboot: Bool = false

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

    func loadFile(data: Data, fileName: String) {
        selectedFileName = fileName
        let bytes = [UInt8](data)

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
        !isRunning && loadedBlocks != nil
    }

    func startFlash(transport: UdsTransport) {
        guard let blocks = loadedBlocks, !isRunning else { return }

        isRunning = true
        isDone = false
        finalError = nil
        logLines.removeAll()
        currentStep = ""; currentStatus = ""; currentProgress = 0

        var options = Simos18FlashOptions(moduleType: moduleType)
        options.shouldPatchCboot = shouldPatchCboot
        switch flashMode {
        case .unlockFlash: options.frfBlocksForUnlock = blocks
        case .normalFlash: options.inputBlocksForNormalFlash = blocks
        case .calOnlyFlash: options.inputBlocksForCalFlash = blocks
        }

        flashTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Simos18FlashOrchestrator.runFlash(
                    transport: transport,
                    options: options,
                    statusCallback: { [weak self] step, status, progress in
                        Task { @MainActor in
                            self?.currentStep = step
                            self?.currentStatus = status
                            self?.currentProgress = progress
                        }
                    },
                    logDetail: { [weak self] message in
                        Task { @MainActor in
                            self?.appendLog(message)
                        }
                    }
                )
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
