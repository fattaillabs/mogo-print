import Compression
import Foundation

/// 평가원 첨부 ZIP을 풀기 위한 작은 ZIP 읽기. 저장(0)·deflate(8) 방식만, ZIP64·암호는 다루지 않는다.
/// 평가원 ZIP은 파일 이름이 CP949(윈도우 한국어)로 들어 있어서 macOS 기본 unzip으로 풀면 이름이 깨진다.
public enum ZipArchive {
    public struct Entry: Sendable {
        /// 폴더 경로를 포함한 이름(ZIP 안의 경로).
        public let path: String
        public let data: Data
        public var name: String { (path as NSString).lastPathComponent }
    }

    public enum ZipError: LocalizedError {
        case notZip
        case corrupt
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notZip: return "ZIP 파일이 아니에요."
            case .corrupt: return "ZIP 파일이 손상됐어요."
            case .unsupported(let what): return "풀 수 없는 ZIP 형식이에요(\(what))."
            }
        }
    }

    /// 파일 항목을 모두 읽는다(폴더 항목은 뺀다).
    public static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // 끝에서부터 중앙 디렉터리 끝 표시(EOCD)를 찾는다.
        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        guard p < bytes.count else { throw ZipError.corrupt }

        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(p + 8), method = u16(p + 10)
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw ZipError.corrupt }
            let path = decodeName(Data(bytes[(p + 46)..<(p + 46 + nameLen)]), utf8: flags & 0x800 != 0)
            p += 46 + nameLen + extraLen + commentLen

            if path.hasSuffix("/") { continue } // 폴더
            if flags & 0x1 != 0 { throw ZipError.unsupported("암호") }
            guard local + 30 <= bytes.count, u32(local) == 0x0403_4B50 else { throw ZipError.corrupt }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { throw ZipError.corrupt }
            let raw = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: out.append(Entry(path: path, data: raw))
            case 8: out.append(Entry(path: path, data: try inflate(raw, size: size)))
            default: throw ZipError.unsupported("압축 방식 \(method)")
            }
        }
        return out
    }

    /// raw deflate(RFC 1951) 풀기. Compression 프레임워크의 ZLIB은 머리말 없는 raw deflate다.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return out
    }

    /// UTF-8 표시가 있으면 UTF-8, 없으면 CP949(윈도우 한국어)로 읽는다.
    static func decodeName(_ raw: Data, utf8: Bool) -> String {
        if utf8 { return String(decoding: raw, as: UTF8.self) }
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        return String(data: raw, encoding: cp949)
            ?? String(data: raw, encoding: .utf8)
            ?? String(decoding: raw, as: UTF8.self)
    }
}
