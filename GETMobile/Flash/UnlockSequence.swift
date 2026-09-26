import Foundation

struct UnlockSequenceOptions {
    /// SA2 script bytes for the target module (Simos18ModuleInfo/Simos1810ModuleInfo.sa2Script).
    let sa2Script: [UInt8]
    let rxID: UInt16
    let txID: UInt16

    /// Workshop code data record written to DID 0xF15A for VW's flash-tool
    /// log. Defaults to the same bytes VW_Flash uses by default
    /// (flash_uds.py's flash_blocks default argument) - a real workshop
    /// code should be substituted here in a later phase rather than left as
    /// this generic default long-term.
    var workshopCode: Data = Data([
        0x20, // Year (BCD/HexDecimal since 2000)
        0x4,  // Month (BCD)
        0x20, // Day (BCD)
        0x42, // Workshop code
        0x04,
        0x20,
        0x42,
        0xB1,
        0x3D,
    ])
}

struct UnlockSequenceResult {
    let vin: String
    let client: UdsClient
}

/// Port of Communication/J2534/Uds/UnlockSequence.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/flash_uds.py - the setup portion of
/// flash_blocks() up through security access unlock and the workshop-log
/// write (everything before the per-block flashing loop).
enum UnlockSequence {
    private static let vinDid: UInt16 = 0xF190
    private static let workshopLogDid: UInt16 = 0xF15A
    private static let programmingPreconditionRoutine: UInt16 = 0x0203
    private static let securityAccessRequestSeedLevel: UInt8 = 0x11 // level 17, odd = request seed
    private static let securityAccessSendKeyLevel: UInt8 = 0x12     // level 17, even = send key

    static func run(
        transport: UdsTransport,
        options: UnlockSequenceOptions,
        logDetail: ((String) -> Void)? = nil,
        statusCallback: ((_ step: String, _ status: String, _ progress: Int) -> Void)? = nil
    ) async throws -> UnlockSequenceResult {
        // "Sending 0x4 Clear Emissions DTCs over OBD-2" - matches
        // flash_uds.py's send_obd() helper: a short-lived exchange on the
        // OBD-II functional broadcast address (rxid=0x7E8, txid=0x700 - NOT
        // the same txid as the main session below, which uses 0x7E0/physical
        // addressing). Deliberately not wrapped in error tolerance here,
        // matching the C# original exactly - a failure at this step aborts
        // the whole unlock sequence there too, not just here.
        statusCallback?("SETUP", "Clearing DTCs ", 100)
        logDetail?("Sending 0x4 Clear Emissions DTCs over OBD-2")
        _ = try await transport.sendRequest(rxID: 0x7E8, txID: 0x700, payload: Data([0x04]), timeoutSeconds: 5)
        _ = try await transport.waitForResponse(timeoutSeconds: 5)

        let client = UdsClient(transport: transport, rxID: options.rxID, txID: options.txID)
        client.requestTimeoutSeconds = 5

        statusCallback?("SETUP", "Entering extended diagnostic session... ", 0)
        logDetail?("Opening extended diagnostic session...")
        try await client.changeSession(.extendedDiagnostic)

        let vin = try await readVinOrThrow(client: client, logDetail: logDetail)
        statusCallback?("SETUP", "Connected to vehicle with VIN: \(vin)", 100)
        logDetail?("Extended diagnostic session connected to vehicle with VIN: \(vin)")

        // F190 is a multi-frame response on these ECUs. Successfully reading
        // it is also a useful proof that the ISO-TP receive path is synchronized
        // before we invoke the programming-precondition routine. Never proceed
        // into flashing if that proof is missing.
        let activeSession = try await client.readDataByIdentifier(0xF186)
        logDetail?("Active diagnostic session DID 0xF186: \((activeSession.map { String(format: "%02X", $0) }).joined(separator: " "))")

        statusCallback?("SETUP", "Checking programming precondition", 100)
        logDetail?("Checking programming precondition, routine 0x0203...")
        try await client.startRoutine(programmingPreconditionRoutine)

        try await client.testerPresent()

        statusCallback?("SETUP", "Upgrading to programming session...", 100)
        logDetail?("Upgrading to programming session...")
        try await enterProgrammingSession(client: client)

        // "Fix timeouts to work around setups which lie about their response speed" - matches the Python exactly.
        client.requestTimeoutSeconds = 30

        try await client.testerPresent()

        statusCallback?("SETUP", "Performing Seed/Key authentication...", 100)
        logDetail?("Performing Seed/Key authentication...")
        try await client.unlockSecurityAccess(requestSeedLevel: securityAccessRequestSeedLevel,
                                               sendKeyLevel: securityAccessSendKeyLevel,
                                               sa2Script: options.sa2Script)

        try await client.testerPresent()

        statusCallback?("SETUP", "Writing Workshop data...", 100)
        logDetail?("Writing flash tool log to LocalIdentifier 0xF15A...")
        try await client.writeDataByIdentifier(workshopLogDid, data: options.workshopCode)

        try await client.testerPresent()

        return UnlockSequenceResult(vin: vin, client: client)
    }

    /// Mirrors read_data_or_empty(): on any failure (negative response,
    /// timeout, malformed payload), log and return "" rather than throwing -
    /// VIN read failing shouldn't abort the whole unlock sequence. Broader
    /// than the C#'s 3-specific-exception-type catch, since each of the 3
    /// transports has its own timeout error type rather than one shared
    /// J2534-specific exception - the intent (never abort setup over a VIN
    /// read failure) is preserved regardless.
    private static func readVinOrThrow(client: UdsClient, logDetail: ((String) -> Void)?) async throws -> String {
        do {
            let vin = try await client.readDataByIdentifierAsAscii(vinDid)
            logDetail?("VIN read succeeded: \(vin)")
            return vin
        } catch {
            logDetail?("VIN read failed; refusing to continue to programming precondition: \(error.localizedDescription)")
            throw error
        }
    }

    /// Mirrors the Python's try/except: normal DiagnosticSessionControl
    /// first; if the ECU refuses (conditions not met, etc.), fall back to
    /// the "switchpatch" raw payload [0x3E, 0x10, 0x02] which some patched
    /// ASWs accept to force entry into programming session even when
    /// conditions aren't nominally met, with widened timeouts for that attempt.
    private static func enterProgrammingSession(client: UdsClient) async throws {
        do {
            try await client.changeSession(.programming)
        } catch {
            client.requestTimeoutSeconds = 30
            let switchpatchPayload = Data([0x3E, 0x10, 0x02])
            let response = try await client.sendRawRequest(switchpatchPayload)
            _ = try UdsPdu.parseResponse(.diagnosticSessionControl, response, hasSubfunctionEcho: true)
        }
    }
}
