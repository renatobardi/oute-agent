import Foundation

/// De onde o tray lê: o endereço do agent-studio e a credencial de leitura (ADR-08 §6), que mora só no
/// `~/.oute/agent.env` do host. O tray lê o arquivo a cada início e nunca copia nem registra o valor.
public struct TrayConfig {
    public enum LoadError: Error, Equatable {
        case missingToken
        case invalidURL

        public var message: String {
            switch self {
            case .missingToken: return "\(TrayConfig.tokenName) ausente em ~/.oute/agent.env (rode: oute secrets refresh)"
            case .invalidURL: return "\(TrayConfig.urlName) precisa ser um endereço https"
            }
        }
    }

    public static let tokenName = "AGENT_STUDIO_READ_TOKEN"
    public static let urlName = "OUTE_AGENT_STUDIO_URL"
    public static let defaultBaseURL = "https://agent-studio.oute.pro"

    public let readToken: String
    public let baseURL: URL

    public var trayURL: URL { baseURL.appendingPathComponent("v1/tray") }

    /// O endereço de uma página do agent-studio ("ver script", a tela) a partir do caminho que a API devolve.
    /// `nil` = o caminho não fica dentro do agent-studio, e o tray não abre.
    public func pageURL(path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let url = URL(string: baseURL.absoluteString + path),
              url.scheme == "https", url.host == baseURL.host, url.port == baseURL.port else { return nil }
        return url
    }

    /// `agentEnv` = o texto do `agent.env` (uma linha `export NOME=<valor>` por variável, como o `oute` grava);
    /// `environment` = o ambiente do processo, de onde vem o `OUTE_AGENT_STUDIO_URL` que o `oute tray install` leu do `.env`.
    public static func load(agentEnv: String, environment: [String: String]) throws -> TrayConfig {
        var token: String?
        let prefix = "export \(tokenName)="
        for line in agentEnv.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            token = unquote(line.dropFirst(prefix.count))
        }
        guard let token, !token.isEmpty else { throw LoadError.missingToken }
        return TrayConfig(readToken: token, baseURL: try baseURL(environment[urlName]))
    }

    private static func baseURL(_ configured: String?) throws -> URL {
        var text = configured ?? ""
        if text.isEmpty { text = defaultBaseURL }
        while text.hasSuffix("/") { text.removeLast() }
        guard let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw LoadError.invalidURL }
        return url
    }

    /// Desfaz o `%q` do bash nas formas simples: texto puro, `\x`, `'…'` e `"…"`. Outra forma (`$'…'`) = `nil`.
    private static func unquote(_ value: Substring) -> String? {
        if value.hasPrefix("$'") { return nil }
        for quote in ["'", "\""] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        var out = "", escaped = false
        for character in value {
            if escaped {
                out.append(character); escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return escaped ? nil : out
    }
}
