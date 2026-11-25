import CoreAudio
import Foundation

/// E15 S6: how an output device is connected, read from `kAudioDevicePropertyTransportType`. A pure mapping, so every
/// constant is testable without hardware. Control plane only; the engine never reads it.
enum OutputTransportKind: String, Codable, Equatable, Sendable, CaseIterable {
    case builtIn
    case usb
    case fireWire
    case thunderbolt
    case pci
    case hdmi
    case displayPort
    case bluetooth
    case bluetoothLE
    case airPlay
    case aggregate
    case virtual
    case unknown

    /// Maps a Core Audio transport-type constant. Any value not listed (including AVB and Continuity today) is `.unknown`.
    init(coreAudioTransportType value: UInt32) {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .unknown
        }
    }

    /// Bluetooth, Bluetooth LE and AirPlay: the device adds a variable delay that the app cannot see.
    var isWireless: Bool {
        switch self {
        case .bluetooth, .bluetoothLE, .airPlay: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .fireWire: return "FireWire"
        case .thunderbolt: return "Thunderbolt"
        case .pci: return "PCI"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .bluetooth: return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .airPlay: return "AirPlay"
        case .aggregate: return "Aggregate"
        case .virtual: return "Virtual"
        case .unknown: return "Unknown"
        }
    }

    /// The wireless name used in notes: "AirPlay" or "Bluetooth".
    var wirelessName: String { self == .airPlay ? "AirPlay" : "Bluetooth" }
}
