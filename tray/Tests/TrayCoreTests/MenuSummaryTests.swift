import XCTest
import TrayCore

final class MenuSummaryTests: XCTestCase {
    private func leitura() throws -> TraySnapshot {
        try TraySnapshot.decode(Fixture.data("tray.json"))
    }

    private func maquinas(_ states: [String]) throws -> [TraySnapshot.Machine] {
        let json = "[" + states.enumerated().map { "{\"host\":\"h\($0.offset)\",\"state\":\"\($0.element)\"}" }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([TraySnapshot.Machine].self, from: Data(json.utf8))
    }

    private func alertas(_ count: Int) throws -> [TraySnapshot.Alert] {
        let json = "[" + (0..<count).map { "{\"title\":\"alerta \($0)\"}" }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([TraySnapshot.Alert].self, from: Data(json.utf8))
    }

    func testMaquinasTodasAtivas() throws {
        XCTAssertEqual(MenuText.machinesSummary(try leitura().machines), "Máquinas: 2 ativas")
        XCTAssertEqual(MenuText.machinesSummary(try maquinas(["active"])), "Máquinas: 1 ativa")
    }

    func testMaquinasComAlgumaForaDoAr() throws {
        XCTAssertEqual(MenuText.machinesSummary(try maquinas(["active", "stopped", "active"])), "Máquinas: 2 de 3 ativas")
        XCTAssertEqual(MenuText.machinesSummary(try maquinas(["stopped"])), "Máquinas: 0 de 1 ativa")
    }

    func testSemMaquina() throws {
        XCTAssertEqual(MenuText.machinesSummary([]), "Máquinas: nenhuma")
    }

    func testAteTresAlertasFicamTodosNoMenu() throws {
        for count in 0...3 {
            let parts = MenuText.alertParts(try alertas(count))
            XCTAssertEqual(parts.shown.count, count)
            XCTAssertTrue(parts.hidden.isEmpty)
        }
    }

    func testAlemDeTresOsPrimeirosFicamEORestoVaiParaOSubmenu() throws {
        let parts = MenuText.alertParts(try alertas(5))
        XCTAssertEqual(parts.shown.map(\.title), ["alerta 0", "alerta 1", "alerta 2"])
        XCTAssertEqual(parts.hidden.map(\.title), ["alerta 3", "alerta 4"])
    }

    func testLinhaDosAlertasQueSobram() {
        XCTAssertEqual(MenuText.moreAlerts(1), "mais 1 alerta…")
        XCTAssertEqual(MenuText.moreAlerts(2), "mais 2 alertas…")
    }

    func testTituloDosAlertasDizOTotal() throws {
        XCTAssertEqual(MenuText.alertsHeader(try alertas(5)), "Alertas: 5")
    }
}
