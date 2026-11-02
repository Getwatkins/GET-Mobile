import Foundation

/// Stand-in transport used ONLY in Demo mode so every screen (Logging,
/// Diagnostics, Flash ECU, ...) can be opened and looked at with no vehicle.
/// It never talks to anything: every request fails immediately with a clear
/// "Demo mode" message, so nothing can reach an ECU (or flash one).
@MainActor
final class DemoTransport: UdsTransport {
    static let shared = DemoTransport()

    struct DemoError: LocalizedError {
        var errorDescription: String? { "Demo mode - no ECU is connected. Connect to your vehicle to use this." }
    }

    private init() {}

    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double) async throws -> Data {
        throw DemoError()
    }

    func waitForResponse(timeoutSeconds: Double) async throws -> Data {
        throw DemoError()
    }

    func disconnect() {}
}
