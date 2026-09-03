import Foundation

/// Minimal protobuf walker for the grok.com gRPC-web billing payload.
/// Ported from onWatch / CodexBar heuristics.
struct ProtobufScan {
    struct Fixed32Hit {
        var path: [UInt64]
        var value: Float
    }

    struct VarintHit {
        var path: [UInt64]
        var value: UInt64
    }

    var fixed32: [Fixed32Hit] = []
    var varints: [VarintHit] = []

    mutating func merge(_ other: ProtobufScan) {
        fixed32.append(contentsOf: other.fixed32)
        varints.append(contentsOf: other.varints)
    }
}

enum ProtobufScanner {
    static func scan(_ data: Data, path: [UInt64] = [], depth: Int = 0) -> ProtobufScan {
        var result = ProtobufScan()
        guard depth < 8 else { return result }
        var i = 0
        let bytes = [UInt8](data)

        while i < bytes.count {
            guard let (tag, tagEnd) = readVarint(bytes, at: i) else { break }
            i = tagEnd
            let field = tag >> 3
            let wire = tag & 0x7
            let nextPath = path + [field]

            switch wire {
            case 0: // varint
                guard let (val, end) = readVarint(bytes, at: i) else { return result }
                i = end
                result.varints.append(.init(path: nextPath, value: val))
            case 1: // 64-bit
                guard i + 8 <= bytes.count else { return result }
                i += 8
            case 2: // length-delimited
                guard let (len, end) = readVarint(bytes, at: i) else { return result }
                i = end
                let length = Int(len)
                guard length >= 0, i + length <= bytes.count else { return result }
                let sub = Data(bytes[i..<(i + length)])
                i += length
                result.merge(scan(sub, path: nextPath, depth: depth + 1))
            case 5: // 32-bit
                guard i + 4 <= bytes.count else { return result }
                let raw = Data(bytes[i..<(i + 4)])
                i += 4
                let value = raw.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
                result.fixed32.append(.init(path: nextPath, value: value))
            default:
                return result
            }
        }
        return result
    }

    private static func readVarint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 {
                return (result, i)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

enum GRPCWebParser {
    struct Frame {
        var flags: UInt8
        var payload: Data
    }

    static func frames(from data: Data) -> [Frame] {
        var out: [Frame] = []
        var i = 0
        let bytes = [UInt8](data)
        while i + 5 <= bytes.count {
            let flags = bytes[i]
            let length = (Int(bytes[i + 1]) << 24)
                | (Int(bytes[i + 2]) << 16)
                | (Int(bytes[i + 3]) << 8)
                | Int(bytes[i + 4])
            i += 5
            guard length >= 0, i + length <= bytes.count else { break }
            out.append(.init(flags: flags, payload: Data(bytes[i..<(i + length)])))
            i += length
        }
        return out
    }

    static func validateTrailers(_ data: Data) throws {
        for frame in frames(from: data) where frame.flags & 0x80 != 0 {
            let text = String(data: frame.payload, encoding: .utf8) ?? ""
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2 else { continue }
                if parts[0].lowercased() == "grpc-status", parts[1] != "0" {
                    throw GrokError.parseFailed
                }
            }
        }
    }
}
