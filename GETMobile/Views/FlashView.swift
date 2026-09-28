import SwiftUI
import UniformTypeIdentifiers

struct FlashView: View {
    @ObservedObject var session: FlashSessionViewModel
    let transport: UdsTransport
    let onDone: () -> Void

    @State private var showFilePicker = false
    @State private var showSafetyConfirmation = false
    @State private var acknowledgedRisk = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(session.target == .tcm ? "Flash TCM" : "Flash ECU")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(GETTheme.gold)
                    .padding(.top, 16)

                warningBanner

                if session.isRunning {
                    progressSection
                } else {
                    setupSection
                }

                if !session.logLines.isEmpty {
                    logSection
                }

                if session.isDone {
                    doneSection
                }

                if let error = session.finalError {
                    Text("Failed: \(error)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(GETTheme.warningRed)
                        .padding(.horizontal)
                }

                Button(session.isRunning ? "Cancel" : "Close") {
                    if session.isRunning {
                        session.cancelFlash()
                    } else {
                        onDone()
                    }
                }
                .foregroundColor(session.isRunning ? GETTheme.warningRed : .gray)
                .padding(.vertical, 12)
            }
            .padding(.horizontal)
        }
        .background(GETTheme.background.ignoresSafeArea())
        .withTopLogo()
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .confirmationDialog(
            session.target == .tcm ? "This will modify your TCM" : "This will modify your ECU",
            isPresented: $showSafetyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Flashing", role: .destructive) {
                session.startFlash(transport: transport)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do not disconnect Bluetooth, close the app, or lose vehicle power during this process. Interrupting a write in progress can leave the \(session.target == .tcm ? "TCM" : "ECU") in an unrecoverable state. Make sure your device is charged and stays connected.")
        }
    }

    // MARK: Setup (pre-flash) section

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledSection(title: "Target") {
                Picker("Target", selection: $session.target) {
                    ForEach(FlashTarget.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            if session.target == .ecm {
                ecmOptions
            } else {
                tcmOptions
            }

            labeledSection(title: "File") {
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc")
                        Text(session.selectedFileName ?? "Choose a .bin file…")
                        Spacer()
                    }
                    .padding(10)
                    .background(GETTheme.panelBackground)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.border, lineWidth: 1))
                }

                ForEach(session.loadWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundColor(GETTheme.amber)
                }

                if session.target == .ecm, session.loadedBlocks != nil {
                    Label("All 5 blocks recognized", systemImage: "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
                if session.target == .tcm, session.loadedTcmBytes != nil {
                    Label(session.tcmFileSummary, systemImage: "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
            }

            Toggle(session.target == .tcm ? "I understand this will modify my TCM and accept the risk" : "I understand this will modify my ECU and accept the risk", isOn: $acknowledgedRisk)
                .tint(GETTheme.warningRed)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 4)

            Button {
                showSafetyConfirmation = true
            } label: {
                Text("Begin Flash Process")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(session.canStart && acknowledgedRisk ? GETTheme.warningRed : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(!session.canStart || !acknowledgedRisk)
        }
    }

    // MARK: Per-target option blocks

    private var ecmOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledSection(title: "ECU Module") {
                Picker("Module", selection: $session.moduleType) {
                    Text("Simos18.1").tag(Simos18ModuleType.simos18_1)
                    Text("Simos18.10").tag(Simos18ModuleType.simos18_10)
                }
                .pickerStyle(.segmented)
            }

            labeledSection(title: "Flash Mode") {
                Picker("Mode", selection: $session.flashMode) {
                    ForEach(FlashMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(session.flashMode.explanation)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            if session.flashMode == .unlockFlash {
                Toggle("Patch CBOOT into sample mode", isOn: $session.shouldPatchCboot)
                    .tint(GETTheme.amber)
                    .font(.system(size: 14))
            }
        }
    }

    private var tcmOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledSection(title: "TCM Type") {
                Picker("TCM", selection: $session.dsgModuleType) {
                    Text("DQ250").tag(DsgModuleType.dq250)
                    Text("DQ381").tag(DsgModuleType.dq381)
                }
                .pickerStyle(.segmented)

                Text(session.dsgModuleType == .dq250
                     ? "CAL-only. Also uploads the small flash-loader (\"Driver\") to the TCM's RAM first - required to write CAL on this unit, and it runs on the TCM. The application software (ASW) is never written. Needs a full 1.5 MB \"F\" image."
                     : "CAL-only. The bootloader and application software are never written. Needs a full 1.5 MB \"F\" image.")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)

                Text("Use a battery charger/maintainer on the car, ignition on, engine off, car stationary, and don't lock your phone. Uses the slower, safer frame pacing - a TCM flash takes noticeably longer than a CAL flash on the ECM.")
                    .font(.system(size: 12))
                    .foregroundColor(GETTheme.amber)
            }
        }
    }

    // MARK: Progress (during flash) section

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("FLASHING IN PROGRESS — DO NOT DISCONNECT", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.black)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(GETTheme.warningRed)
                .cornerRadius(6)

            Text(session.currentStep)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(GETTheme.gold)
            Text(session.currentStatus)
                .font(.system(size: 13))
                .foregroundColor(.white)

            ProgressView(value: Double(session.currentProgress), total: 100)
                .tint(GETTheme.gold)
        }
    }

    private var doneSection: some View {
        Label("Flash completed successfully", systemImage: "checkmark.seal.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.green)
            .padding(.vertical, 8)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log").font(.system(size: 13, weight: .bold)).foregroundColor(.gray)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(session.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(8)
            .background(GETTheme.panelBackground)
            .cornerRadius(6)
        }
    }

    private var warningBanner: some View {
        Text("Flashing writes directly to your \(session.target == .tcm ? "TCM" : "ECU")'s memory. A failure mid-write can require dealer-level recovery. Keep your device charged, stay near the vehicle, and don't lock your phone during the process.")
            .font(.system(size: 12))
            .foregroundColor(GETTheme.amber)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    private func labeledSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.gray)
            content()
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return }
        session.loadFile(data: data, fileName: url.lastPathComponent)
    }
}
