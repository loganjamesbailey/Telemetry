import Foundation
import IOKit

/// Low-level client for the AppleSMC IOKit user client.
///
/// Not thread-safe by design — callers own serialization (the daemon uses a
/// serial queue; the app's sensor engine polls from a single queue).
public final class SMCClient {
    private var connection: io_connect_t = 0
    /// keyInfo results never change for a given key on a given machine; cache
    /// them so 1 Hz polling costs one call per key instead of two.
    private var keyInfoCache: [UInt32: SMCParamStruct.KeyInfo] = [:]

    public init() throws {
        precondition(
            MemoryLayout<SMCParamStruct>.stride == 80,
            "SMCParamStruct must be exactly 80 bytes; layout drifted"
        )
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Core call

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCKernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        return output
    }

    // MARK: - Reads (no privileges required)

    public func keyInfo(_ key: String) throws -> SMCParamStruct.KeyInfo {
        let keyCode = try UInt32(smcCode: key)
        if let cached = keyInfoCache[keyCode] { return cached }

        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMCOperation.readKeyInfo.rawValue
        let output = try call(&input)
        if output.result == SMCResult.keyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == SMCResult.ok else {
            throw SMCError.smcResult(output.result, key: key)
        }
        keyInfoCache[keyCode] = output.keyInfo
        return output.keyInfo
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// Two-phase read: key info (cached) then bytes.
    public func readBytes(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = try UInt32(smcCode: key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCOperation.readBytes.rawValue
        let output = try call(&input)
        guard output.result == SMCResult.ok else {
            throw SMCError.smcResult(output.result, key: key)
        }
        let count = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { raw in
            Array(raw.prefix(count))
        }
        return (info.dataType.smcCode, bytes)
    }

    public func readFloat(_ key: String) throws -> Float {
        let (type, bytes) = try readBytes(key)
        guard type == SMCDataType.flt else {
            throw SMCError.unexpectedType(key: key, expected: SMCDataType.flt, actual: type)
        }
        guard let value = SMCDecode.float(bytes) else {
            throw SMCError.smcResult(0xFF, key: key)
        }
        return value
    }

    public func readUInt(_ key: String) throws -> UInt {
        let (_, bytes) = try readBytes(key)
        guard let value = SMCDecode.uint(bytes) else {
            throw SMCError.smcResult(0xFF, key: key)
        }
        return value
    }

    // MARK: - Key enumeration

    public func keyCount() throws -> Int {
        Int(try readUInt("#KEY"))
    }

    /// Key name at `index` via the readIndex operation.
    public func keyName(at index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = SMCOperation.readIndex.rawValue
        input.data32 = UInt32(index)
        let output = try call(&input)
        guard output.result == SMCResult.ok else {
            throw SMCError.smcResult(output.result, key: "#\(index)")
        }
        return output.key.smcCode
    }

    public func allKeys() throws -> [String] {
        let count = try keyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            if let key = try? keyName(at: i) { keys.append(key) }
        }
        return keys
    }

    // MARK: - Writes (root required)

    /// Single write attempt. Checks the firmware result byte — IOKit returning
    /// success does NOT mean the write happened (firmware rejections come back
    /// as result 0x82 with kIOReturnSuccess).
    public func writeBytes(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.dataSize) else {
            throw SMCError.unexpectedType(
                key: key,
                expected: "\(info.dataSize) bytes",
                actual: "\(bytes.count) bytes"
            )
        }
        var input = SMCParamStruct()
        input.key = try UInt32(smcCode: key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCOperation.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.enumerated() where i < 32 { raw[i] = b }
        }
        let output = try call(&input)
        guard output.result == SMCResult.ok else {
            throw SMCError.smcResult(output.result, key: key)
        }
    }

    /// Writes fail transiently on Apple Silicon even as root; retry with a
    /// short delay. `notPrivileged` is permanent and rethrown immediately.
    public func writeWithRetry(
        _ key: String,
        bytes: [UInt8],
        attempts: Int = 10,
        delayMs: UInt32 = 50
    ) throws {
        var lastError: Error = SMCError.smcResult(0xFF, key: key)
        for attempt in 0..<max(1, attempts) {
            do {
                try writeBytes(key, bytes: bytes)
                return
            } catch SMCError.notPrivileged {
                throw SMCError.notPrivileged
            } catch {
                lastError = error
                if attempt < attempts - 1 { usleep(delayMs * 1000) }
            }
        }
        throw lastError
    }

    public func writeFloat(_ key: String, _ value: Float, attempts: Int = 10) throws {
        try writeWithRetry(key, bytes: SMCDecode.encodeFloat(value), attempts: attempts)
    }

    public func writeUInt8(_ key: String, _ value: UInt8, attempts: Int = 10) throws {
        try writeWithRetry(key, bytes: [value], attempts: attempts)
    }
}
