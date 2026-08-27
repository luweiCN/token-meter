import Foundation

/// gRPC-web `GetGrokCreditsConfig` 的最小解码：只要百分比和重置时间。
/// 字段来自 OmniRoute / Tokscale 对 grok.com 的实测（无公开 .proto）。
enum GrokCreditsGrpcParser {
    static func parse(data: Data) throws -> Data {
        let payload = dataFramePayload(in: data) ?? data
        let root = decodeFields(payload)
        let configBytes: Data
        if case let .bytes(nested)? = root[1] {
            configBytes = nested
        } else {
            configBytes = payload
        }
        let fields = decodeFields(configBytes)

        let usedPercent = percent(in: fields) ?? 0

        var object: [String: Any] = ["creditUsagePercent": usedPercent]
        if let reset = timestamp(in: fields, field: 5) ?? timestamp(in: fields, field: 4) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            object["billingPeriodEnd"] = formatter.string(from: reset)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func percent(in fields: [UInt64: ProtoValue]) -> Double? {
        guard let value = float(in: fields, field: 1), value.isFinite else { return 0 }
        let percent = value <= 1 ? value * 100 : value
        let clamped = max(0, min(100, percent))
        return (clamped * 10).rounded() / 10
    }

    private static func float(in fields: [UInt64: ProtoValue], field: UInt64) -> Double? {
        guard case let .bytes(bytes)? = fields[field], bytes.count == 4 else { return nil }
        let bits = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Double(Float(bitPattern: UInt32(littleEndian: bits)))
    }

    private static func timestamp(in fields: [UInt64: ProtoValue], field: UInt64) -> Date? {
        guard case let .bytes(bytes)? = fields[field] else { return nil }
        let nested = decodeFields(bytes)
        guard case let .varint(seconds)? = nested[1] else { return nil }
        var nanos: Double = 0
        if case let .varint(value)? = nested[2] {
            nanos = Double(value) / 1_000_000_000
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + nanos)
    }

    private static func dataFramePayload(in data: Data) -> Data? {
        var offset = 0
        while offset + 5 <= data.count {
            let flag = data[offset]
            let length = data.subdata(in: (offset + 1)..<(offset + 5)).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            }
            let start = offset + 5
            let end = start + Int(length)
            guard end <= data.count else { return nil }
            if flag & 0x80 == 0 {
                return data.subdata(in: start..<end)
            }
            offset = end
        }
        return nil
    }

    private enum ProtoValue {
        case varint(UInt64)
        case bytes(Data)
    }

    private static func decodeFields(_ data: Data) -> [UInt64: ProtoValue] {
        var fields: [UInt64: ProtoValue] = [:]
        var offset = 0
        while offset < data.count {
            guard let (tag, afterTag) = readVarint(data, offset) else { break }
            let field = tag >> 3
            let wire = tag & 7
            offset = afterTag
            switch wire {
            case 0:
                guard let (value, next) = readVarint(data, offset) else { return fields }
                fields[field] = .varint(value)
                offset = next
            case 1:
                guard offset + 8 <= data.count else { return fields }
                fields[field] = .bytes(data.subdata(in: offset..<(offset + 8)))
                offset += 8
            case 2:
                guard let (length, bodyStart) = readVarint(data, offset) else { return fields }
                let bodyEnd = bodyStart + Int(length)
                guard bodyEnd <= data.count else { return fields }
                fields[field] = .bytes(data.subdata(in: bodyStart..<bodyEnd))
                offset = bodyEnd
            case 5:
                guard offset + 4 <= data.count else { return fields }
                fields[field] = .bytes(data.subdata(in: offset..<(offset + 4)))
                offset += 4
            default:
                return fields
            }
        }
        return fields
    }

    private static func readVarint(_ data: Data, _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.count {
            let byte = data[index]
            result |= UInt64(byte & 0x7f) << shift
            index += 1
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
