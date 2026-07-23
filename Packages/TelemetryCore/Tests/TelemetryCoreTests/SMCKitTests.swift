import XCTest
@testable import SMCKit

final class SMCKitTests: XCTestCase {
    func testParamStructIs80Bytes() {
        // The kernel expects exactly 80 bytes; any drift breaks every call.
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
    }

    func testFourCCRoundTrip() throws {
        for code in ["FNum", "F0Ac", "F0Md", "F0md", "Tp01", "#KEY", "Ftst", "flt "] {
            let packed = try UInt32(smcCode: code)
            XCTAssertEqual(packed.smcCode, code)
        }
    }

    func testFourCCKnownValue() throws {
        // "FNum" = 0x464E756D big-endian packing
        XCTAssertEqual(try UInt32(smcCode: "FNum"), 0x464E_756D)
    }

    func testFourCCRejectsWrongLength() {
        XCTAssertThrowsError(try UInt32(smcCode: "abc"))
        XCTAssertThrowsError(try UInt32(smcCode: "abcde"))
        XCTAssertThrowsError(try UInt32(smcCode: ""))
    }

    func testFloatCodecRoundTrip() {
        for value: Float in [0, 1191.5, 4000, 7199, 0.25] {
            let bytes = SMCDecode.encodeFloat(value)
            XCTAssertEqual(bytes.count, 4)
            XCTAssertEqual(SMCDecode.float(bytes), value)
        }
    }

    func testFloatDecodeRejectsNonFinite() {
        XCTAssertNil(SMCDecode.float(SMCDecode.encodeFloat(.infinity)))
        XCTAssertNil(SMCDecode.float([0, 0, 0xC0, 0x7F]))  // NaN bit pattern
        XCTAssertNil(SMCDecode.float([0, 0]))  // short buffer
    }

    func testUIntDecodeBigEndian() {
        XCTAssertEqual(SMCDecode.uint([0x01]), 1)
        XCTAssertEqual(SMCDecode.uint([0x01, 0x00]), 256)
        XCTAssertEqual(SMCDecode.uint([0x00, 0x00, 0x01, 0x2C]), 300)
        XCTAssertNil(SMCDecode.uint([]))
    }

    func testSp78Decode() {
        XCTAssertEqual(SMCDecode.sp78([0x2A, 0x80]), 42.5)  // 0x2A80 / 256
        XCTAssertEqual(SMCDecode.sp78([0xFF, 0x00]), -1.0)  // signed
    }

    func testFpe2Decode() {
        XCTAssertEqual(SMCDecode.fpe2([0x0B, 0xB8]), 750.0)  // 3000 >> 2
    }
}
