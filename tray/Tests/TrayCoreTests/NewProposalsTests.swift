import XCTest
import TrayCore

final class NewProposalsTests: XCTestCase {
    /// Uma leitura do `/v1/tray` só com os pedidos pendentes dados (o resto do menu vazio).
    private func leitura(_ ids: [String], disponivel: Bool = true) throws -> TraySnapshot {
        let pending = ids.map { "{\"id\": \"\($0)\", \"title\": \"Pedido \($0)\", \"host\": \"oute-mac\"}" }.joined(separator: ",")
        let json = """
        {"bar": {"pending": \(disponivel ? String(ids.count) : "null"), "alerts": 0}, "machines": [],
         "proposals": {"available": \(disponivel), "total": \(disponivel ? String(ids.count) : "null"), "pending": [\(pending)]},
         "cost_today": {"usd": 0, "estimated": false, "agents": []},
         "errors_last_hour": {"total": 0, "rows": []}, "alerts": []}
        """
        return try TraySnapshot.decode(Data(json.utf8))
    }

    private let a = "20261003-100000-a", b = "20261003-100100-b", c = "20261003-100200-c"

    func testPrimeiraLeituraNaoAvisaNada() throws {
        var vistos = SeenProposals()
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b])).map(\.id), [])
    }

    func testSoOPedidoAindaNaoVistoEAvisado() throws {
        var vistos = SeenProposals()
        _ = vistos.newProposals(in: try leitura([a]))
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b])).map(\.id), [b])
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b])).map(\.id), [])
        XCTAssertEqual(vistos.newProposals(in: try leitura([c, b])).map(\.id), [c])
    }

    func testPedidoQueSomeEVoltaNaoAvisaDeNovo() throws {
        var vistos = SeenProposals()
        _ = vistos.newProposals(in: try leitura([a]))
        _ = vistos.newProposals(in: try leitura([]))
        XCTAssertEqual(vistos.newProposals(in: try leitura([a])).map(\.id), [])
    }

    func testPrimeiraLeituraSemPedidosAvisaOPrimeiroQueChegar() throws {
        var vistos = SeenProposals()
        _ = vistos.newProposals(in: try leitura([]))
        XCTAssertEqual(vistos.newProposals(in: try leitura([a])).map(\.id), [a])
    }

    func testSurrealDBForaNoMeioNaoRepeteAviso() throws {
        var vistos = SeenProposals()
        _ = vistos.newProposals(in: try leitura([a]))
        XCTAssertEqual(vistos.newProposals(in: try leitura([], disponivel: false)).map(\.id), [])
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b])).map(\.id), [b])
    }

    func testSurrealDBForaNaPrimeiraLeituraNaoContaComoPrimeira() throws {
        var vistos = SeenProposals()
        _ = vistos.newProposals(in: try leitura([], disponivel: false))
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b])).map(\.id), [])
        XCTAssertEqual(vistos.newProposals(in: try leitura([a, b, c])).map(\.id), [c])
    }
}
