import Foundation

/// O arquivo `.icns` do app (#563): cabeçalho `icns` + tamanho total, e cada imagem como tipo + tamanho + PNG.
/// Os tamanhos vão em 4 bytes, do mais alto para o mais baixo. O PNG de cada entrada quem desenha é o app.
public enum IconFile {
    public struct Entry {
        public let type: String
        public let png: Data

        public init(type: String, png: Data) {
            self.type = type
            self.png = png
        }
    }

    /// Os tipos que o macOS lê como PNG e o lado de cada um, em pixels (16 a 512 pt, em 1x e 2x).
    public static let appSizes: [(type: String, pixels: Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]

    public static func icns(_ entries: [Entry]) -> Data {
        var body = Data()
        for entry in entries {
            body.append(contentsOf: Array(entry.type.utf8))
            body.append(contentsOf: bigEndian(8 + entry.png.count))
            body.append(entry.png)
        }
        var file = Data("icns".utf8)
        file.append(contentsOf: bigEndian(8 + body.count))
        file.append(body)
        return file
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) }
    }
}
