import XCTest
import TrayCore

final class SnapshotTests: XCTestCase {
    func testBarraMostraPendentesEAlertas() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.barTitle, "3 · 1")
    }

    func testBarraSemSurrealDBMostraInterrogacaoNosPendentes() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray-sem-surrealdb.json"))
        XCTAssertEqual(snapshot.barTitle, "? · 1")
    }

    func testMaquinas() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.machines.map(\.host), ["oute-mac", "oute-server"])
        XCTAssertEqual(snapshot.machines[0].state, "active")
        XCTAssertEqual(snapshot.machines[0].idleSeconds, 12)
    }

    func testPedidosPendentes() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.proposals.pending.count, 3)
        let pedido = snapshot.proposals.pending[1]
        XCTAssertEqual(pedido.id, "20261003-135500-reiniciar-nginx")
        XCTAssertEqual(pedido.title, "Reiniciar nginx")
        XCTAssertEqual(pedido.runAs, "root")
        XCTAssertEqual(pedido.agent, "claude")
        XCTAssertEqual(pedido.host, "oute-server")
        XCTAssertEqual(pedido.ageSeconds, 300)
        XCTAssertEqual(pedido.url, "/pedido?id=20261003-135500-reiniciar-nginx")
    }

    func testSemSurrealDBNaoHaPedidosENaoEstaDisponivel() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray-sem-surrealdb.json"))
        XCTAssertFalse(snapshot.proposals.available)
        XCTAssertEqual(snapshot.proposals.pending, [])
    }

    func testCustoDeHojeTotalEPorAgenteComEstimadoMarcado() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.costToday.usd, 5.5404)
        XCTAssertTrue(snapshot.costToday.estimated)
        XCTAssertEqual(snapshot.costToday.unpricedCalls, 1)
        XCTAssertEqual(snapshot.costToday.agents.map(\.agent), ["claude", "codex"])
        XCTAssertEqual(snapshot.costToday.agents[1].usd, 2.51)
        XCTAssertEqual(snapshot.costToday.agents[1].unpricedCalls, 1)
    }

    func testErrosDaUltimaHora() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.errorsLastHour.total, 3)
        XCTAssertEqual(snapshot.errorsLastHour.rows.map(\.total), [2, 1])
        XCTAssertEqual(snapshot.errorsLastHour.rows[0].host, "oute-mac")
        XCTAssertEqual(snapshot.errorsLastHour.rows[0].agent, "codex")
    }

    func testAlertasTrazemTituloETextoDaAPI() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.alerts.count, 1)
        XCTAssertEqual(snapshot.alerts[0].title, "Fila do collector acima do limite")
        XCTAssertEqual(snapshot.alerts[0].text, "80% da fila (limite 50%)")
        XCTAssertEqual(snapshot.alerts[0].host, "oute-server")
    }

    func testDecisoesPendentesDoSwarm() throws {
        let snapshot = try TraySnapshot.decode(Fixture.data("tray.json"))
        XCTAssertEqual(snapshot.decisions?.pending.map(\.question), ["1. aprovar a triagem  2. cortar a #387"])
        XCTAssertEqual(snapshot.decisions?.pending[0].round, "swarm-1003-1211")
    }
}
