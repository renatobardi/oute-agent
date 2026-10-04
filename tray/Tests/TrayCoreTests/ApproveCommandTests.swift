import XCTest
import TrayCore

final class ProposalIDTests: XCTestCase {
    func testIdDoOutePropose() {
        XCTAssertTrue(ProposalID.isValid("20261003-135500-reiniciar-nginx"))
        XCTAssertTrue(ProposalID.isValid("20261004-000131-tray-260-ler-versao-do-swift-e-do-macos-"))
    }

    func testIdForaDoFormatoERecusado() {
        XCTAssertFalse(ProposalID.isValid(""))
        XCTAssertFalse(ProposalID.isValid("p <b>5</b>&x=é"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-"))
        XCTAssertFalse(ProposalID.isValid("2026103-135500-x"))
        XCTAssertFalse(ProposalID.isValid("20261003-13550-x"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-Reiniciar"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-a_b"))
    }

    func testIdQueTentaSairDoComandoERecusado() {
        XCTAssertFalse(ProposalID.isValid("20261003-135500-x; rm -rf ~"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-x$(id)"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-x'"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-x\n"))
        XCTAssertFalse(ProposalID.isValid("20261003-135500-x\nid"))
        XCTAssertFalse(ProposalID.isValid(" 20261003-135500-x"))
        // dígitos que não são ASCII
        XCTAssertFalse(ProposalID.isValid("２０２６１００３-135500-x"))
    }
}

final class ApproveCommandTests: XCTestCase {
    private let hosts = TrayHosts(text: "oute-mac=local\noute-server=servidor\n")

    private func pedidos() throws -> [TraySnapshot.Proposal] {
        try TraySnapshot.decode(Fixture.data("tray.json")).proposals.pending
    }

    func testPedidoDoProprioMacAbreOOuteApprove() throws {
        XCTAssertEqual(ApproveCommand.command(for: try pedidos()[2], hosts: hosts),
                       "oute approve 20261003-134000-listar-backups")
    }

    func testPedidoDeOutroHostVaiPorSshComOAliasDaTabela() throws {
        XCTAssertEqual(ApproveCommand.command(for: try pedidos()[1], hosts: hosts),
                       "ssh -t servidor 'bash -lc \"oute approve 20261003-135500-reiniciar-nginx\"'")
    }

    func testIdInvalidoNaoTemComando() throws {
        XCTAssertNil(ApproveCommand.command(for: try pedidos()[0], hosts: hosts))
    }

    func testHostForaDaTabelaNaoTemComando() throws {
        XCTAssertNil(ApproveCommand.command(for: try pedidos()[1], hosts: TrayHosts(text: "oute-mac=local\n")))
        XCTAssertNil(ApproveCommand.command(for: try pedidos()[2], hosts: TrayHosts(text: "")))
    }
}
