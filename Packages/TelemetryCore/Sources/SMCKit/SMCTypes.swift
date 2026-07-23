import Foundation
import IOKit

/// The 80-byte parameter struct exchanged with the AppleSMC user client.
///
/// Layout must match the kernel's expectation exactly. The explicit `padding`
/// field reproduces the C compiler's alignment so the Swift struct is also
/// 80 bytes — asserted at connection time and in tests.
public struct SMCParamStruct {
    public typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    public struct Version {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
    }

    public struct PLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
    }

    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
    }

    public var key: UInt32 = 0
    public var vers = Version()
    public var pLimitData = PLimitData()
    public var keyInfo = KeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}
}

/// SMC operation selectors, passed in `SMCParamStruct.data8`.
/// The kernel call selector itself is always 2.
public enum SMCOperation: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

public let kSMCKernelIndex: UInt32 = 2

/// SMC firmware result codes returned in `SMCParamStruct.result`.
public enum SMCResult {
    public static let ok: UInt8 = 0x00
    public static let keyNotFound: UInt8 = 0x84
    public static let notWritable: UInt8 = 0x85
    /// Returned when firmware rejects a write (e.g. thermalmonitord-protected
    /// fan-mode keys before an Ftst unlock).
    public static let badCommand: UInt8 = 0x82
}

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    /// IOKit accepted the call but the SMC firmware reported a non-zero result.
    /// A write that hits this was silently dropped by the firmware.
    case smcResult(UInt8, key: String)
    case keyNotFound(String)
    case notPrivileged
    case unexpectedType(key: String, expected: String, actual: String)
    case invalidKey(String)
    case writeVerifyFailed(key: String)
    case cancelled

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed: \(String(format: "0x%08X", kr))"
        case .callFailed(let kr): return "IOConnectCallStructMethod failed: \(String(format: "0x%08X", kr))"
        case .smcResult(let r, let key): return "SMC firmware result 0x\(String(format: "%02X", r)) for key \(key)"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .notPrivileged: return "SMC write requires root (kIOReturnNotPrivileged)"
        case .unexpectedType(let key, let expected, let actual):
            return "Key \(key) has type '\(actual)', expected '\(expected)'"
        case .invalidKey(let key): return "Invalid SMC key (must be 4 ASCII chars): \(key)"
        case .writeVerifyFailed(let key): return "Write to \(key) did not read back"
        case .cancelled: return "Operation cancelled"
        }
    }
}

/// Four-character SMC key/type codes, packed big-endian into a UInt32.
public extension UInt32 {
    init(smcCode string: String) throws {
        guard string.utf8.count == 4 else { throw SMCError.invalidKey(string) }
        self = string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var smcCode: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

/// Known SMC data-type codes (the 4-char strings from key info).
public enum SMCDataType {
    public static let flt = "flt "   // 4-byte little-endian IEEE-754 float (Apple Silicon)
    public static let ui8 = "ui8 "
    public static let ui16 = "ui16"
    public static let ui32 = "ui32"
    public static let sp78 = "sp78"  // signed fixed-point 7.8, big-endian (legacy temps)
    public static let fpe2 = "fpe2"  // unsigned fixed-point 14.2, big-endian (Intel fans)
    public static let flag = "flag"
}

/// Decoders for raw SMC byte payloads.
public enum SMCDecode {
    public static func float(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 4 else { return nil }
        let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let value = Float(bitPattern: raw)
        return value.isFinite ? value : nil
    }

    public static func encodeFloat(_ value: Float) -> [UInt8] {
        let raw = value.bitPattern
        return [
            UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF),
        ]
    }

    public static func uint(_ bytes: [UInt8]) -> UInt? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return bytes.reduce(UInt(0)) { ($0 << 8) | UInt($1) }  // big-endian
    }

    public static func sp78(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Float(raw) / 256.0
    }

    public static func fpe2(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Float(raw) / 4.0
    }

    /// Best-effort human-readable decode for the `list` command / sensor browser.
    public static func describe(type: String, bytes: [UInt8]) -> String {
        switch type {
        case SMCDataType.flt:
            if let v = float(bytes) { return String(format: "%.2f", v) }
        case SMCDataType.ui8, SMCDataType.ui16, SMCDataType.ui32:
            if let v = uint(bytes) { return "\(v)" }
        case SMCDataType.sp78:
            if let v = sp78(bytes) { return String(format: "%.2f", v) }
        case SMCDataType.fpe2:
            if let v = fpe2(bytes) { return String(format: "%.2f", v) }
        case SMCDataType.flag:
            if let first = bytes.first { return first == 0 ? "false" : "true" }
        default:
            break
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
