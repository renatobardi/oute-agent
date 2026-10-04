import XCTest
import TrayCore

final class AgeTests: XCTestCase {
    func testSegundos() {
        XCTAssertEqual(Age.text(seconds: 12), "há 12 s")
    }

    func testMinutosHorasEDiasArredondamParaBaixo() {
        XCTAssertEqual(Age.text(seconds: 59), "há 59 s")
        XCTAssertEqual(Age.text(seconds: 60), "há 1 min")
        XCTAssertEqual(Age.text(seconds: 300), "há 5 min")
        XCTAssertEqual(Age.text(seconds: 3599), "há 59 min")
        XCTAssertEqual(Age.text(seconds: 3600), "há 1 h")
        XCTAssertEqual(Age.text(seconds: 86399), "há 23 h")
        XCTAssertEqual(Age.text(seconds: 86400), "há 1 d")
        XCTAssertEqual(Age.text(seconds: 259200), "há 3 d")
    }

    func testIdadeNegativaViraZero() {
        XCTAssertEqual(Age.text(seconds: -5), "há 0 s")
    }

    func testSemLeituraDizHaQuantoTempo() {
        let ultima = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Age.sinceLastRead(ultima, now: ultima.addingTimeInterval(95)), "sem leitura há 1 min")
    }

    func testSemLeituraNenhumaAinda() {
        XCTAssertEqual(Age.sinceLastRead(nil, now: Date(timeIntervalSince1970: 1_000_000)), "sem leitura")
    }
}
