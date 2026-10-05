import XCTest
import TrayCore

final class IconFileTests: XCTestCase {
    func testCabecalhoDizIcnsEOTamanhoDoArquivo() {
        let data = IconFile.icns([IconFile.Entry(type: "ic07", png: Data([1, 2, 3]))])
        XCTAssertEqual(Array(data.prefix(4)), Array("icns".utf8))
        XCTAssertEqual(Array(data[4..<8]), [0, 0, 0, 19])
        XCTAssertEqual(data.count, 19)
    }

    func testCadaEntradaLevaTipoTamanhoEOPng() {
        let data = IconFile.icns([IconFile.Entry(type: "ic07", png: Data([1, 2, 3])),
                                  IconFile.Entry(type: "ic08", png: Data([9]))])
        XCTAssertEqual(Array(data[8..<12]), Array("ic07".utf8))
        XCTAssertEqual(Array(data[12..<16]), [0, 0, 0, 11])
        XCTAssertEqual(Array(data[16..<19]), [1, 2, 3])
        XCTAssertEqual(Array(data[19..<23]), Array("ic08".utf8))
        XCTAssertEqual(Array(data[23..<27]), [0, 0, 0, 9])
        XCTAssertEqual(Array(data[27..<28]), [9])
        XCTAssertEqual(Array(data[4..<8]), [0, 0, 0, 28])
    }

    func testTamanhosDoIconeDoApp() {
        XCTAssertEqual(IconFile.appSizes.map(\.pixels), [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])
        XCTAssertEqual(Set(IconFile.appSizes.map(\.type)).count, IconFile.appSizes.count)
        XCTAssertTrue(IconFile.appSizes.allSatisfy { $0.type.utf8.count == 4 })
    }
}
