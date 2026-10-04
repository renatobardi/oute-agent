import XCTest
import TrayCore

final class TrayHostsTests: XCTestCase {
    func testLocalEAlias() {
        let hosts = TrayHosts(text: "oute-mac=local\noute-server=oute-server\n")
        XCTAssertEqual(hosts.target(for: "oute-mac"), .local)
        XCTAssertEqual(hosts.target(for: "oute-server"), .ssh(alias: "oute-server"))
        XCTAssertNil(hosts.target(for: "outro"))
    }

    func testComentarioLinhaVaziaEEspacos() {
        let hosts = TrayHosts(text: "# tabela do tray\n\n  oute-mac = local  \r\noute-server=bardi@servidor.ts.net # tailnet\n")
        XCTAssertEqual(hosts.target(for: "oute-mac"), .local)
        XCTAssertEqual(hosts.target(for: "oute-server"), .ssh(alias: "bardi@servidor.ts.net"))
    }

    func testAliasQueViraOpcaoOuComandoEIgnorado() {
        let hosts = TrayHosts(text: """
        a=-oProxyCommand=id
        b=servidor; id
        c=servidor'
        d=$(id)
        e=
        f=ser vidor
        """)
        for host in ["a", "b", "c", "d", "e", "f"] {
            XCTAssertNil(hosts.target(for: host), host)
        }
    }

    func testLinhaSemIgualOuSemHostEIgnorada() {
        let hosts = TrayHosts(text: "oute-mac\n=local\n")
        XCTAssertNil(hosts.target(for: "oute-mac"))
        XCTAssertNil(hosts.target(for: ""))
    }

    func testUltimaLinhaDoMesmoHostVale() {
        let hosts = TrayHosts(text: "oute-server=antigo\noute-server=novo\n")
        XCTAssertEqual(hosts.target(for: "oute-server"), .ssh(alias: "novo"))
    }
}
