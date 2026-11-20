import CryptoKit

private let lowercaseHexDigits = Array("0123456789abcdef".utf8)

extension SHA256.Digest {
    package var lowercaseHex: String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount * 2)
        for byte in self {
            bytes.append(lowercaseHexDigits[Int(byte >> 4)])
            bytes.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
