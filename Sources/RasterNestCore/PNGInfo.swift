import Foundation

/// Reads a PNG's pixel size and density from its header, without an image library (works on Linux).
public struct PNGInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Pixels per point from the pHYs chunk (144 dpi → 2), 1 when absent.
    public var scale: Double

    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(4096))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 33, Array(bytes[0..<8]) == signature else { return nil }
        func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
        guard String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" else { return nil }
        width = u32(16)
        height = u32(20)
        scale = 1
        // Walk the chunks that fit in the prefix looking for pHYs (pixels per metre).
        var i = 8
        while i + 12 <= bytes.count {
            let length = u32(i)
            let type = String(bytes: bytes[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            if type == "pHYs", i + 17 <= bytes.count, bytes[i + 16] == 1 {
                let dpi = Double(u32(i + 8)) * 0.0254
                scale = max(1, (dpi / 72 * 2).rounded() / 2)
                break
            }
            if type == "IDAT" || type == "IEND" { break }
            i += 12 + length
        }
    }
}
