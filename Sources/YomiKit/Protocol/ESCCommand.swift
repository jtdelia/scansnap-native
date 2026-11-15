/// Two-byte `1B xx` commands of the S300/S1300 family, as used by
/// ScanSnap Manager.
public enum ESCCommand: UInt8, Sendable {
    case hardwareStatus = 0x03
    case firmwareDownload = 0x06
    case hardwareInfo = 0x13
    case firmwareBoot = 0x16
    case firmwarePrepare = 0x17
    case eepromRead = 0x24
    case sensorInfo = 0x33
    case imageLengthInfo = 0x43
    case cancel = 0x55
    case secondEEPROMRead = 0x64
    case energySaving = 0xB0
    case paperLengthDetection = 0xB2
    case overScan = 0xB3
    case doubleFeedDetection = 0xB4
    case thermistor = 0xB5
    case shadingBlack = 0xC3
    case shadingWhite = 0xC4
    case lut = 0xC5
    case agcSet = 0xC6
    case agcGet = 0xC7
    case lamp = 0xD0
    case setWindow = 0xD1
    case littleImageBlock = 0xD2
    case imageBlock = 0xD3
    case paper = 0xD4
    case startPage = 0xD6
    case powerLED = 0xE1

    var bytes: [UInt8] { [0x1B, rawValue] }
}
