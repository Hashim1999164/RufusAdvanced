import Testing
@testable import BootKit
@Test func placeholder() { #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF43926) }
