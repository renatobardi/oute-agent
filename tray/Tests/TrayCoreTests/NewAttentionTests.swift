import XCTest
import TrayCore

final class NewAttentionTests: XCTestCase {
    private struct Aviso {
        let kind: String
        let key: String?
        let at: Int
        var round = "swarm-1004-1000"
    }

    /// Uma leitura do `/v1/tray` só com os avisos dados (o resto do menu vazio). `comBloco: false` = agent-studio antigo.
    private func leitura(_ avisos: [Aviso], comBloco: Bool = true) throws -> TraySnapshot {
        let rows = avisos.map { (a: Aviso) -> String in
            let key = a.key.map { "\"\($0)\"" } ?? "null"
            let id = "\(a.round)|\(a.kind)|\(a.key ?? "")|\(a.at)"
            return """
            {"id": "\(id)", "round": "\(a.round)", "name": null, "kind": "\(a.kind)", "key": \(key),
             "title": "Aviso \(a.kind)", "at": "2026-10-04T10:00:00Z", "age_seconds": 60, "url": "/rodada?id=\(a.round)"}
            """
        }.joined(separator: ",")
        let bloco = comBloco ? ", \"attention\": {\"total\": \(avisos.count), \"rows\": [\(rows)]}" : ""
        let json = """
        {"bar": {"pending": 0, "alerts": 0}, "machines": [],
         "proposals": {"available": true, "total": 0, "pending": []}\(bloco),
         "cost_today": {"usd": 0, "estimated": false, "agents": []},
         "errors_last_hour": {"total": 0, "rows": []}, "alerts": []}
        """
        return try TraySnapshot.decode(Data(json.utf8))
    }

    private let ci13 = Aviso(kind: "ci", key: "13", at: 100)
    private let bloqueada = Aviso(kind: "blocked", key: "7", at: 200)
    private let merge12 = Aviso(kind: "merged", key: "12", at: 300)
    private let pergunta = Aviso(kind: "question", key: nil, at: 400)

    func testPrimeiraLeituraNaoAvisaNada() throws {
        var vistos = SeenAttention()
        let mudanca = vistos.update(with: try leitura([ci13, bloqueada]))
        XCTAssertEqual(mudanca.fresh, [])
        XCTAssertEqual(mudanca.resolved, [])
    }

    func testSoOItemNovoEAvisadoUmaVez() throws {
        var vistos = SeenAttention()
        _ = vistos.update(with: try leitura([ci13]))
        XCTAssertEqual(vistos.update(with: try leitura([ci13, merge12])).fresh.map(\.kind), ["merged"])
        XCTAssertEqual(vistos.update(with: try leitura([ci13, merge12])).fresh, [])
    }

    func testItemQueDeixaDeValerSaiENaoVoltaComOMesmoId() throws {
        var vistos = SeenAttention()
        _ = vistos.update(with: try leitura([ci13, bloqueada]))
        let saiu = vistos.update(with: try leitura([ci13]))
        XCTAssertEqual(saiu.resolved, ["swarm-1004-1000|blocked|7|200"])
        XCTAssertEqual(saiu.fresh, [])
        // a mesma ocorrência de volta (leitura que oscilou) não avisa de novo
        XCTAssertEqual(vistos.update(with: try leitura([ci13, bloqueada])).fresh, [])
    }

    func testMesmoFatoDepoisDeResolvidoEOutraOcorrencia() throws {
        var vistos = SeenAttention()
        _ = vistos.update(with: try leitura([ci13]))
        _ = vistos.update(with: try leitura([]))
        let denovo = Aviso(kind: "ci", key: "13", at: 900)
        XCTAssertEqual(vistos.update(with: try leitura([denovo])).fresh.map(\.id), ["swarm-1004-1000|ci|13|900"])
    }

    func testPrimeiraLeituraSemAvisosAvisaOPrimeiroQueChegar() throws {
        var vistos = SeenAttention()
        _ = vistos.update(with: try leitura([]))
        XCTAssertEqual(vistos.update(with: try leitura([pergunta])).fresh.map(\.kind), ["question"])
    }

    func testMesmoTipoEmOutraRodadaEAvisoNovo() throws {
        var vistos = SeenAttention()
        _ = vistos.update(with: try leitura([ci13]))
        let outra = Aviso(kind: "ci", key: "13", at: 100, round: "swarm-1004-1100")
        XCTAssertEqual(vistos.update(with: try leitura([ci13, outra])).fresh.map(\.round), ["swarm-1004-1100"])
    }

    func testAgentStudioSemOBlocoNaoAvisaENaoAtrapalha() throws {
        var vistos = SeenAttention()
        XCTAssertEqual(vistos.update(with: try leitura([], comBloco: false)), SeenAttention.Change(fresh: [], resolved: []))
        _ = vistos.update(with: try leitura([ci13]))
        XCTAssertEqual(vistos.update(with: try leitura([], comBloco: false)), SeenAttention.Change(fresh: [], resolved: []))
        XCTAssertEqual(vistos.update(with: try leitura([ci13, merge12])).fresh.map(\.key), ["12"])
    }

    func testFixtureTemUmAvisoDeCadaTipoComAPaginaDaRodada() throws {
        let avisos = try XCTUnwrap(try TraySnapshot.decode(Fixture.data("tray.json")).attention)
        XCTAssertEqual(avisos.total, 4)
        XCTAssertEqual(Set(avisos.rows.map(\.kind)), ["ci", "blocked", "question", "merged"])
        XCTAssertEqual(avisos.rows[0].url, "/rodada?id=swarm-1003-1211")
        XCTAssertNil(avisos.rows[0].key)
        XCTAssertEqual(avisos.rows[2].id, "swarm-1003-1211|ci|13|1791034800000000000")
    }

    func testFixtureSemSurrealDBTemOBlocoVazio() throws {
        let avisos = try XCTUnwrap(try TraySnapshot.decode(Fixture.data("tray-sem-surrealdb.json")).attention)
        XCTAssertEqual(avisos.rows, [])
        XCTAssertEqual(avisos.total, 0)
    }

    func testTextoDoMenuTrazTituloRodadaEIdade() throws {
        let item = try XCTUnwrap(try TraySnapshot.decode(Fixture.data("tray.json")).attention).rows[2]
        XCTAssertEqual(MenuText.attention(item), "CI reprovado no PR #13 · Brave_Otter (swarm-1003-1211) · há 20 min")
        XCTAssertEqual(MenuText.attentionBody(item), "Brave_Otter (swarm-1003-1211) · há 20 min")
        XCTAssertEqual(MenuText.attentionHeader(try XCTUnwrap(try TraySnapshot.decode(Fixture.data("tray.json")).attention)),
                       "Avisos das rodadas: 4")
    }
}
