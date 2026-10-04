import XCTest
import TrayCore

final class TrayConfigTests: XCTestCase {
    /// Credencial de mentira, nova a cada teste.
    private let token = UUID().uuidString

    func testTokenDeLeituraVemDoAgentEnv() throws {
        let config = try TrayConfig.load(agentEnv: "export OCI_REGION=sa-saopaulo-1\nexport AGENT_STUDIO_READ_TOKEN=\(token)\n", environment: [:])
        XCTAssertEqual(config.readToken, token)
    }

    func testEnderecoPadraoDoAgentStudio() throws {
        let config = try TrayConfig.load(agentEnv: "export AGENT_STUDIO_READ_TOKEN=\(token)\n", environment: [:])
        XCTAssertEqual(config.trayURL.absoluteString, "https://agent-studio.oute.pro/v1/tray")
    }

    func testSemTokenFalhaDizendoOQueFalta() {
        for agentEnv in ["", "export OCI_REGION=x\n", "export AGENT_STUDIO_READ_TOKEN=\n", "AGENT_STUDIO_READ_TOKEN_OLD=x\n"] {
            XCTAssertThrowsError(try TrayConfig.load(agentEnv: agentEnv, environment: [:])) { error in
                XCTAssertEqual(error as? TrayConfig.LoadError, .missingToken)
            }
        }
    }

    func testValorComoOPrintfQDoBashEscreve() throws {
        // o `oute` grava cada linha com `printf 'export %s=%q'`: texto simples, com barra de escape ou entre aspas
        let casos: [(String, String)] = [
            ("abc\\+def\\=", "abc+def="),
            ("'abc def'", "abc def"),
            ("\"abc def\"", "abc def"),
            ("\(token)", token),
        ]
        for (escrito, esperado) in casos {
            let config = try TrayConfig.load(agentEnv: "export AGENT_STUDIO_READ_TOKEN=\(escrito)\n", environment: [:])
            XCTAssertEqual(config.readToken, esperado, escrito)
        }
    }

    func testFormaQueOTrayNaoSabeLerContaComoTokenAusente() {
        XCTAssertThrowsError(try TrayConfig.load(agentEnv: "export AGENT_STUDIO_READ_TOKEN=$'a\\nb'\n", environment: [:])) { error in
            XCTAssertEqual(error as? TrayConfig.LoadError, .missingToken)
        }
    }

    func testEnderecoDoAmbienteTrocaOPadrao() throws {
        let agentEnv = "export AGENT_STUDIO_READ_TOKEN=\(token)\n"
        let config = try TrayConfig.load(agentEnv: agentEnv, environment: ["OUTE_AGENT_STUDIO_URL": "https://studio.exemplo.ts.net/"])
        XCTAssertEqual(config.trayURL.absoluteString, "https://studio.exemplo.ts.net/v1/tray")
        let vazio = try TrayConfig.load(agentEnv: agentEnv, environment: ["OUTE_AGENT_STUDIO_URL": ""])
        XCTAssertEqual(vazio.trayURL.absoluteString, "https://agent-studio.oute.pro/v1/tray")
    }

    func testEnderecoQueNaoEHttpsERecusado() {
        // a credencial de leitura vai no cabeçalho: só sai por https
        let agentEnv = "export AGENT_STUDIO_READ_TOKEN=\(token)\n"
        for endereco in ["http" + "://agent-studio.oute.pro", "agent-studio.oute.pro", "https://", "file:///etc/passwd", "https://u:p@exemplo.ts.net"] {
            XCTAssertThrowsError(try TrayConfig.load(agentEnv: agentEnv, environment: ["OUTE_AGENT_STUDIO_URL": endereco]), endereco) { error in
                XCTAssertEqual(error as? TrayConfig.LoadError, .invalidURL)
            }
        }
    }

    func testErroNuncaLevaOValorDoToken() {
        XCTAssertFalse("\(TrayConfig.LoadError.missingToken)".contains(token))
        XCTAssertEqual(TrayConfig.LoadError.missingToken.message, "AGENT_STUDIO_READ_TOKEN ausente em ~/.oute/agent.env (rode: oute secrets refresh)")
        XCTAssertEqual(TrayConfig.LoadError.invalidURL.message, "OUTE_AGENT_STUDIO_URL precisa ser um endereço https")
    }

    func testVerScriptAbreAPaginaDoPedidoNoAgentStudio() throws {
        let config = try TrayConfig.load(agentEnv: "export AGENT_STUDIO_READ_TOKEN=\(token)\n", environment: [:])
        let pedidos = try TraySnapshot.decode(Fixture.data("tray.json")).proposals.pending
        XCTAssertEqual(config.pageURL(path: pedidos[1].url)?.absoluteString,
                       "https://agent-studio.oute.pro/pedido?id=20261003-135500-reiniciar-nginx")
        XCTAssertEqual(config.pageURL(path: pedidos[0].url)?.absoluteString,
                       "https://agent-studio.oute.pro/pedido?id=p%20%3Cb%3E5%3C/b%3E%26x%3D%C3%A9")
        XCTAssertEqual(config.pageURL(path: "/")?.absoluteString, "https://agent-studio.oute.pro/")
    }

    func testCaminhoQueSaiDoAgentStudioNaoAbre() throws {
        let config = try TrayConfig.load(agentEnv: "export AGENT_STUDIO_READ_TOKEN=\(token)\n", environment: [:])
        for caminho in [nil, "", "pedido?id=x", "//outro.exemplo/pedido", "https://outro.exemplo/pedido", "/\\outro.exemplo"] {
            XCTAssertNil(config.pageURL(path: caminho), caminho ?? "nil")
        }
    }
}
