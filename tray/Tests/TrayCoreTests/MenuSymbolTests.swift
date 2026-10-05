import XCTest
import TrayCore

final class MenuSymbolTests: XCTestCase {
    func testAmbarSoNoPedidoENaDecisaoPendentes() {
        let comGate = MenuSymbol.allCases.filter { $0.tint == .gate }
        XCTAssertEqual(Set(comGate), [.pendingProposal, .pendingDecision])
    }

    func testOGateUsaUmSimboloSo() {
        XCTAssertEqual(MenuSymbol.pendingProposal.systemName, MenuSymbol.pendingDecision.systemName)
    }

    func testErroEAlertaUsamOMesmoSimboloSemCor() {
        let avisos: [MenuSymbol] = [.notice, .errors, .alerts]
        XCTAssertEqual(Set(avisos.map(\.systemName)).count, 1)
        XCTAssertTrue(avisos.allSatisfy { $0.tint == .mono })
    }

    func testOSimboloDoGateNaoApareceEmLinhaSemCor() {
        let gate = MenuSymbol.pendingProposal.systemName
        XCTAssertFalse(MenuSymbol.allCases.contains { $0.tint == .mono && $0.systemName == gate })
    }

    func testTodoSimboloTemNome() {
        XCTAssertTrue(MenuSymbol.allCases.allSatisfy { !$0.systemName.isEmpty })
    }
}
