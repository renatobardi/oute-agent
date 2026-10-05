import XCTest
import TrayCore

final class SakuraTests: XCTestCase {
    func testPetalaComecaNoCentroTemQuatroCurvasEFecha() throws {
        let segments = try XCTUnwrap(Sakura.segments(Sakura.petalPath))
        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(segments.first, .move(Sakura.Point(x: 50, y: 50)))
        XCTAssertEqual(segments[1], .curve(control1: Sakura.Point(x: 38, y: 43), control2: Sakura.Point(x: 33, y: 27),
                                           to: Sakura.Point(x: 39, y: 15)))
        XCTAssertEqual(segments[4], .curve(control1: Sakura.Point(x: 67, y: 27), control2: Sakura.Point(x: 62, y: 43),
                                           to: Sakura.Point(x: 50, y: 50)))
        XCTAssertEqual(segments.last, .close)
    }

    func testEstameEUmaLinhaDoCentroParaCima() {
        XCTAssertEqual(Sakura.segments(Sakura.stamenPath),
                       [.move(Sakura.Point(x: 50, y: 50)), .line(Sakura.Point(x: 50, y: 34))])
    }

    func testCincoPetalasECincoEstamesIntercalados() {
        XCTAssertEqual(Sakura.petalAngles, [0, 72, 144, 216, 288])
        XCTAssertEqual(Sakura.stamenAngles, [36, 108, 180, 252, 324])
    }

    func testCaminhoQueOTrayNaoSabeLerERecusado() {
        XCTAssertNil(Sakura.segments("M50,50 Q10,10 20,20"))
        XCTAssertNil(Sakura.segments("M50,50 L50"))
        XCTAssertNil(Sakura.segments("M50,x"))
        XCTAssertNil(Sakura.segments("50,50"))
    }
}
