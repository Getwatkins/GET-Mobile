import CoreBluetooth

/// Everything here is taken directly from the esp32-isotp-ble-bridge
/// (BridgeLEG branch) firmware source - main/ble_server.c and
/// main/isotp_bridge.c - not guessed. This is the same firmware SimosTools,
/// VW_Flash's BLEISOTP interface, and the Macchina A0 community already use
/// for both logging and flashing Simos18 ECUs over BLE.
enum BridgeProtocol {

    // MARK: GATT UUIDs
    // The firmware advertises a 16-bit "SPP" service (0xABF0) with four
    // 16-bit characteristics. CoreBluetooth wants full 128-bit UUIDs, so
    // these are the official Bluetooth Base UUID with the 16-bit value
    // dropped in (0000XXXX-0000-1000-8000-00805F9B34FB) - standard expansion,
    // not something we get to choose.
    static let serviceUUID           = CBUUID(string: "0000ABF0-0000-1000-8000-00805F9B34FB")
    static let dataReceiveUUID       = CBUUID(string: "0000ABF1-0000-1000-8000-00805F9B34FB") // phone writes UDS requests here
    static let dataNotifyUUID        = CBUUID(string: "0000ABF2-0000-1000-8000-00805F9B34FB") // firmware notifies UDS responses here
    static let commandReceiveUUID    = CBUUID(string: "0000ABF3-0000-1000-8000-00805F9B34FB") // settings/password writes
    static let commandNotifyUUID     = CBUUID(string: "0000ABF4-0000-1000-8000-00805F9B34FB") // settings/password acks

    /// Firmware's default advertised local name (ble_server.h: DEFAULT_GAP_NAME).
    /// Bridges can be renamed via the BRG_SETTING_GAP setting, so this is a
    /// hint for the scan list, not a hard filter.
    static let defaultDeviceName = "BLE_TO_ISOTP20"

    /// Firmware's default BLE password (constants.h: PASSWORD_DEFAULT),
    /// sent proactively on connect. Harmless no-op on firmware builds with
    /// PASSWORD_CHECK compiled out; required on builds that have it enabled.
    static let defaultPassword = "BLE2"

    // MARK: ble_header_t flags (ble_server.h)
    static let headerID: UInt8       = 0xF1   // ble_header_t.hdID - marks the start of a fresh (non-continuation) frame
    static let partialID: UInt8      = 0xF2   // marks a continuation chunk: [0xF2][chunk_num][...bytes]

    static let flagPerEnable: UInt8      = 1
    static let flagPerClear: UInt8       = 2
    static let flagPerAdd: UInt8         = 4
    static let flagSplitPacket: UInt8    = 8    // more continuation chunks follow this one
    static let flagSettingsGet: UInt8    = 64
    static let flagSettings: UInt8       = 128

    // MARK: Settings IDs (constants.h BRG_SETTING_*), used with flagSettings
    static let settingIsotpStmin: UInt8      = 1
    static let settingLedColor: UInt8        = 2
    static let settingPersistDelay: UInt8    = 3
    static let settingPersistQDelay: UInt8   = 4
    static let settingBleSendDelay: UInt8    = 5
    static let settingBleMultiDelay: UInt8   = 6
    static let settingPassword: UInt8        = 7
    static let settingGap: UInt8             = 8

    /// Standard OBD functional addressing for Simos18 - identical constants
    /// the existing GET Flasher Windows app already uses
    /// (Communication/Simos18/Simos18ModuleInfo.cs: Rxid=0x7E8, Txid=0x7E0),
    /// and the convention every other Simos18 tool in this ecosystem uses.
    static let simos18RequestID: UInt16  = 0x7E0  // txID - the CAN ID we transmit UDS requests on
    static let simos18ResponseID: UInt16 = 0x7E8  // rxID - the CAN ID we expect the ECU's response on
}
