import Foundation
import Compression

/// A tiny, dependency-free ZIP reader.
/// EPUB files are ZIP archives, so this is enough to crack one open.
/// Stored (method 0) and DEFLATE (method 8) entries are supported;
/// DEFLATE is inflated with Apple's `Compression` framework (raw deflate == COMPRESSION_ZLIB).
struct ZipEntry {
    let path: String
    let method: Int           // 0 = stored, 8 = deflate
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

final class MiniZip {
    private let bytes: [UInt8]
    private(set) var entries: [String: ZipEntry] = [:]
    private(set) var order: [String] = []

    init?(data: Data) {
        self.bytes = [UInt8](data)
        guard parseCentralDirectory() else { return nil }
    }

    convenience init?(url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d)
    }

    // MARK: - Little-endian readers

    private func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
    private func u32(_ o: Int) -> Int {
        Int(bytes[o]) | (Int(bytes[o + 1]) << 8) | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
    }

    // MARK: - Central directory

    private func parseCentralDirectory() -> Bool {
        let n = bytes.count
        guard n > 22 else { return false }

        // Locate End Of Central Directory record (sig 0x06054b50), scanning backwards.
        var eocd = -1
        var i = n - 22
        let minI = max(0, n - 22 - 65_536)
        while i >= minI {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return false }

        let total = u16(eocd + 10)
        var off = u32(eocd + 16)            // offset of first central-directory header

        for _ in 0..<total {
            guard off + 46 <= n, u32(off) == 0x0201_4b50 else { break }
            let method   = u16(off + 10)
            let compSize = u32(off + 20)
            let uncomp   = u32(off + 24)
            let nameLen  = u16(off + 28)
            let extraLen = u16(off + 30)
            let cmntLen  = u16(off + 32)
            let localOff = u32(off + 42)
            let nameStart = off + 46
            guard nameStart + nameLen <= n else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLen], as: UTF8.self)
            let entry = ZipEntry(path: name, method: method,
                                 compressedSize: compSize, uncompressedSize: uncomp,
                                 localHeaderOffset: localOff)
            entries[name] = entry
            order.append(name)
            off = nameStart + nameLen + extraLen + cmntLen
        }
        return !entries.isEmpty
    }

    // MARK: - Extraction

    func data(for path: String) -> Data? {
        guard let e = entries[path] else { return nil }
        let lo = e.localHeaderOffset
        guard lo + 30 <= bytes.count,
              bytes[lo] == 0x50, bytes[lo + 1] == 0x4b, bytes[lo + 2] == 0x03, bytes[lo + 3] == 0x04
        else { return nil }

        let nameLen  = u16(lo + 26)
        let extraLen = u16(lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard start + e.compressedSize <= bytes.count else { return nil }
        if e.compressedSize == 0 { return Data() }

        let comp = Array(bytes[start..<start + e.compressedSize])
        switch e.method {
        case 0: return Data(comp)
        case 8: return inflate(comp, expected: e.uncompressedSize)
        default: return nil
        }
    }

    /// Unpack every file entry into `dir`, preserving the internal folder layout.
    func extractAll(to dir: URL) {
        let fm = FileManager.default
        for name in order where !name.hasSuffix("/") {
            guard let d = data(for: name) else { continue }
            let dest = dir.appendingPathComponent(name)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: dest)
        }
    }

    // MARK: - DEFLATE

    private func inflate(_ input: [UInt8], expected: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        var cap = expected > 0 ? expected : max(input.count * 8, 65_536)
        for _ in 0..<8 {
            var dst = [UInt8](repeating: 0, count: cap)
            let written = input.withUnsafeBufferPointer { src in
                dst.withUnsafeMutableBufferPointer { d in
                    compression_decode_buffer(d.baseAddress!, d.count,
                                              src.baseAddress!, src.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < cap { return Data(dst[0..<written]) }
            // written == cap → output likely truncated; grow and retry.
            cap *= 2
        }
        return nil
    }
}
