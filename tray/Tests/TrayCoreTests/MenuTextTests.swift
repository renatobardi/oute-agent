import XCTest
import TrayCore

final class MenuTextTests: XCTestCase {
    private func leitura(_ name: String = "tray.json") throws -> TraySnapshot {
        try TraySnapshot.decode(Fixture.data(name))
    }

    func testMaquinaDizEstadoEUltimoDado() throws {
        XCTAssertEqual(MenuText.machine(try leitura().machines[0]), "oute-mac · ativa · último dado há 12 s")
    }

    func testPedidoDizTituloComoRodaAgenteHostEIdade() throws {
        XCTAssertEqual(MenuText.proposal(try leitura().proposals.pending[1]),
                       "Reiniciar nginx · root · claude · oute-server · há 5 min")
    }

    func testCustoDeHojeMarcaOEstimadoEAsChamadasSemPreco() throws {
        XCTAssertEqual(MenuText.cost(try leitura().costToday), "Custo de hoje: US$ 5,54 (estimado) · 1 chamada sem preço")
    }

    func testCustoPorAgente() throws {
        let agentes = try leitura().costToday.agents
        XCTAssertEqual(MenuText.agentCost(agentes[0]), "claude: US$ 3,03 (estimado)")
        XCTAssertEqual(MenuText.agentCost(agentes[1]), "codex: US$ 2,51 (estimado) · 1 chamada sem preço")
    }

    func testErrosDaUltimaHora() throws {
        let erros = try leitura().errorsLastHour
        XCTAssertEqual(MenuText.errors(erros), "Erros na última hora: 3")
        XCTAssertEqual(MenuText.errorRow(erros.rows[0]), "oute-mac · codex: 2")
    }

    func testAlertaUsaOTituloEOTextoDaAPI() throws {
        XCTAssertEqual(MenuText.alert(try leitura().alerts[0]),
                       "Fila do collector acima do limite: 80% da fila (limite 50%) · oute-server")
    }

    func testDecisaoPendente() throws {
        XCTAssertEqual(MenuText.decision(try XCTUnwrap(try leitura().decisions?.pending.first)),
                       "Brave_Otter (swarm-1003-1211) · 1. aprovar a triagem  2. cortar a #387 · há 10 min")
    }

    func testEtapaAprovadaDizTituloRodadaEIdadeSemVeredito() throws {
        let etapas = try XCTUnwrap(try leitura().steps)
        XCTAssertEqual(MenuText.step(etapas.rows[0]), "Fechamento da rodada · Brave_Otter (swarm-1003-1211) · há 2 min")
    }

    func testEtapaSemRevisorEReprovadaDizemOVeredito() throws {
        let etapas = try XCTUnwrap(try leitura().steps)
        XCTAssertEqual(MenuText.step(etapas.rows[1]), "Pedido de merge #12 · Brave_Otter (swarm-1003-1211) · sem revisor · há 5 min")
        XCTAssertEqual(MenuText.step(etapas.rows[2]), "Triagem · Brave_Otter (swarm-1003-1211) · reprovada pelo revisor · há 40 min")
    }

    func testEtapaDeRodadaAntigaSemNomeMostraSoOId() throws {
        let json = #"{"round":"swarm-1003-1211","kind":"triagem","key":null,"rev":1,"review":"aprovado","title":"Triagem","age_seconds":60}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let etapa = try decoder.decode(TraySnapshot.Step.self, from: Data(json.utf8))
        XCTAssertNil(etapa.name)
        XCTAssertEqual(MenuText.step(etapa), "Triagem · swarm-1003-1211 · há 1 min")
    }

    func testEtapasDizemQuantasHaOuQueEstaIndisponivel() throws {
        XCTAssertEqual(MenuText.stepsHeader(try XCTUnwrap(try leitura().steps)), "Etapas das rodadas abertas: 3")
        XCTAssertEqual(MenuText.stepsHeader(try XCTUnwrap(try leitura("tray-sem-surrealdb.json").steps)),
                       "Etapas das rodadas: ? (estado indisponível)")
    }

    func testPedidosSemSurrealDB() throws {
        XCTAssertEqual(MenuText.proposalsHeader(try leitura("tray-sem-surrealdb.json").proposals), "Pedidos pendentes: ? (estado indisponível)")
        XCTAssertEqual(MenuText.proposalsHeader(try leitura().proposals), "Pedidos pendentes: 3")
    }
}
