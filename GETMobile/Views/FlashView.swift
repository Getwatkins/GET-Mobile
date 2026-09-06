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
                Text("Flash ECU")
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
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .confirmationDialog(
            "This will modify your ECU",
            isPresented: $showSafetyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Flashing", role: .destructive) {
                session.startFlash(transport: transport)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do not disconnect Bluetooth, close the app, or lose vehicle power during this process. Interrupting a write in progress can leave the ECU in an unrecoverable state. Make sure your device is charged and stays connected.")
        }
    }

    // MARK: Setup (pre-flash) section

    private var setupSection: some View {
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

                if session.loadedBlocks != nil {
                    Label("All 5 blocks recognized", systemImage: "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
            }

            Toggle("I understand this will modify my ECU and accept the risk", isOn: $acknowledgedRisk)
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
        Text("Flashing writes directly to your ECU's memory. A failure mid-write can require dealer-level recovery. Keep your device charged, stay near the vehicle, and don't lock your phone during the process.")
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
