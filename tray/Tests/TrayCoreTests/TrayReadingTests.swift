import XCTest
import TrayCore

final class TrayReadingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testLeituraBoaMostraOMenuSemAviso() throws {
        var leitura = TrayReading()
        leitura.received(status: 200, body: try Fixture.data("tray.json"), at: t0)
        XCTAssertEqual(leitura.barTitle, "3 · 1")
        XCTAssertEqual(leitura.snapshot?.proposals.pending.count, 3)
        XCTAssertNil(leitura.notice(now: t0.addingTimeInterval(15)))
    }

    func testFalhaMantemOUltimoMenuEDizHaQuantoTempoNaoLe() throws {
        let falhas: [(inout TrayReading) -> Void] = [
            { $0.failed() },
            { $0.received(status: 401, body: Data("{\"message\": \"sem credencial\"}".utf8), at: self.t0.addingTimeInterval(15)) },
            { $0.received(status: 500, body: Data("{\"message\": \"consulta falhou\"}".utf8), at: self.t0.addingTimeInterval(15)) },
            { $0.received(status: 200, body: Data("<html>".utf8), at: self.t0.addingTimeInterval(15)) },
        ]
        for falha in falhas {
            var leitura = TrayReading()
            leitura.received(status: 200, body: try Fixture.data("tray.json"), at: t0)
            falha(&leitura)
            XCTAssertEqual(leitura.barTitle, "3 · 1")
            XCTAssertEqual(leitura.snapshot?.proposals.pending.count, 3)
            XCTAssertEqual(leitura.notice(now: t0.addingTimeInterval(95)), "sem leitura há 1 min")
        }
    }

    func testAntesDaPrimeiraLeitura() {
        var leitura = TrayReading()
        XCTAssertEqual(leitura.barTitle, "? · ?")
        XCTAssertNil(leitura.snapshot)
        leitura.failed()
        XCTAssertEqual(leitura.barTitle, "? · ?")
        XCTAssertEqual(leitura.notice(now: t0), "sem leitura")
    }

    func testLeituraQueVoltaTiraOAviso() throws {
        var leitura = TrayReading()
        leitura.received(status: 200, body: try Fixture.data("tray.json"), at: t0)
        leitura.failed()
        leitura.received(status: 200, body: try Fixture.data("tray-sem-surrealdb.json"), at: t0.addingTimeInterval(30))
        XCTAssertNil(leitura.notice(now: t0.addingTimeInterval(31)))
        XCTAssertEqual(leitura.barTitle, "? · 1")
    }
}
