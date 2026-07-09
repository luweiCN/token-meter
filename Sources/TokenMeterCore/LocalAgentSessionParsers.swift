import Foundation

public enum LocalAgentParserError: Error, Equatable {
    case missingSessionKey
    case unsupportedFormat
    case incompleteLine
}

enum JSONDictionary {
    static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func dictionary(_ object: [String: Any], _ key: String) -> [String: Any]? {
        dictionary(object[key])
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        string(object[key])
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber where !(value is Bool):
            return number.stringValue
        default:
            return nil
        }
    }

    static func int64(_ object: [String: Any], _ key: String) -> Int64? {
        int64(object[key])
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        case let double as Double where double.isFinite:
            return Int64(double)
        case let number as NSNumber where !(value is Bool):
            return number.int64Value
        case let string as String:
            if let int64 = Int64(string) {
                return int64
            }
            guard let double = Double(string), double.isFinite else {
                return nil
            }
            return Int64(double)
        default:
            return nil
        }
    }

    static func double(_ object: [String: Any], _ key: String) -> Double? {
        double(object[key])
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let double as Double where double.isFinite:
            return double
        case let int as Int:
            return Double(int)
        case let int64 as Int64:
            return Double(int64)
        case let number as NSNumber where !(value is Bool):
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let string as String:
            guard let double = Double(string), double.isFinite else {
                return nil
            }
            return double
        default:
            return nil
        }
    }
}
