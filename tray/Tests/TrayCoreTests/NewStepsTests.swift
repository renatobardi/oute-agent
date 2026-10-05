import XCTest
import TrayCore

final class NewStepsTests: XCTestCase {
    private struct Etapa {
        let round: String
        let kind: String
        let key: String?
        let rev: Int
    }

    /// Uma leitura do `/v1/tray` só com as etapas dadas (o resto do menu vazio). `disponivel: false` = SurrealDB fora.
    private func leitura(_ etapas: [Etapa], disponivel: Bool = true, comBloco: Bool = true) throws -> TraySnapshot {
        let rows = etapas.map { (e: Etapa) -> String in
            let key = e.key.map { "\"\($0)\"" } ?? "null"
            return "{\"round\": \"\(e.round)\", \"kind\": \"\(e.kind)\", \"key\": \(key), \"rev\": \(e.rev), \"review\": \"aprovado\", \"title\": \"Etapa \(e.kind)\"}"
        }.joined(separator: ",")
        let steps = comBloco
            ? ", \"steps\": {\"available\": \(disponivel), \"total\": \(disponivel ? String(etapas.count) : "null"), \"rows\": [\(rows)]}"
            : ""
        let json = """
        {"bar": {"pending": 0, "alerts": 0}, "machines": [],
         "proposals": {"available": true, "total": 0, "pending": []}\(steps),
         "cost_today": {"usd": 0, "estimated": false, "agents": []},
         "errors_last_hour": {"total": 0, "rows": []}, "alerts": []}
        """
        return try TraySnapshot.decode(Data(json.utf8))
    }

    private let triagem = Etapa(round: "swarm-1004-1000", kind: "triagem", key: nil, rev: 1)
    private let merge12 = Etapa(round: "swarm-1004-1000", kind: "merge", key: "12", rev: 1)
    private let merge13 = Etapa(round: "swarm-1004-1000", kind: "merge", key: "13", rev: 1)

    func testPrimeiraLeituraNaoAvisaNada() throws {
        var vistas = SeenSteps()
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem, merge12])).map(\.id), [])
    }

    func testSoAEtapaAindaNaoVistaEAvisada() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([triagem]))
        XCTAssertEqual(vistas.newSteps(in: try leitura([merge12, triagem])).map(\.kind), ["merge"])
        XCTAssertEqual(vistas.newSteps(in: try leitura([merge12, triagem])).map(\.id), [])
        XCTAssertEqual(vistas.newSteps(in: try leitura([merge13, merge12, triagem])).map(\.key), ["13"])
    }

    func testRevisaoNovaDaMesmaEtapaAvisaDeNovo() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([merge12]))
        let revisada = Etapa(round: merge12.round, kind: "merge", key: "12", rev: 2)
        XCTAssertEqual(vistas.newSteps(in: try leitura([revisada])).map(\.rev), [2])
    }

    func testMesmoTipoEmOutraRodadaEEtapaNova() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([triagem]))
        let outra = Etapa(round: "swarm-1004-1100", kind: "triagem", key: nil, rev: 1)
        XCTAssertEqual(vistas.newSteps(in: try leitura([outra, triagem])).map(\.round), ["swarm-1004-1100"])
    }

    func testEtapaQueSomeEVoltaNaoAvisaDeNovo() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([triagem]))
        _ = vistas.newSteps(in: try leitura([]))
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem])).map(\.id), [])
    }

    func testPrimeiraLeituraSemEtapasAvisaAPrimeiraQueChegar() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([]))
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem])).map(\.kind), ["triagem"])
    }

    func testSurrealDBForaNoMeioNaoRepeteAviso() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([triagem]))
        XCTAssertEqual(vistas.newSteps(in: try leitura([], disponivel: false)).map(\.id), [])
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem, merge12])).map(\.key), ["12"])
    }

    func testSurrealDBForaNaPrimeiraLeituraNaoContaComoPrimeira() throws {
        var vistas = SeenSteps()
        _ = vistas.newSteps(in: try leitura([], disponivel: false))
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem, merge12])).map(\.id), [])
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem, merge12, merge13])).map(\.key), ["13"])
    }

    func testAgentStudioSemOBlocoNaoAvisaENaoAtrapalha() throws {
        var vistas = SeenSteps()
        XCTAssertEqual(vistas.newSteps(in: try leitura([], comBloco: false)).map(\.id), [])
        _ = vistas.newSteps(in: try leitura([triagem]))
        XCTAssertEqual(vistas.newSteps(in: try leitura([], comBloco: false)).map(\.id), [])
        XCTAssertEqual(vistas.newSteps(in: try leitura([triagem, merge12])).map(\.key), ["12"])
    }
}
