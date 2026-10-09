import Foundation

/// Uma resposta do `GET /v1/tray` do agent-studio (ADR-08, "Endpoint do tray"): tudo o que o menu mostra.
public struct TraySnapshot: Decodable, Equatable {
    public struct Bar: Decodable, Equatable {
        /// `nil` = o agent-studio não soube dizer (SurrealDB fora): nunca zero por palpite.
        public let pending: Int?
        public let alerts: Int?
    }

    public struct Machine: Decodable, Equatable {
        public let host: String
        public let state: String
        public let alwaysOn: Bool?
        public let lastData: String?
        public let idleSeconds: Int?
    }

    /// Um pedido do canal de aprovação ainda pendente. O `id` vem do container do agente: é dado não confiável.
    public struct Proposal: Decodable, Equatable {
        public let id: String
        public let title: String?
        /// `root` ou `user` (o `as` da API).
        public let runAs: String?
        public let agent: String?
        public let host: String?
        public let instance: String?
        public let ageSeconds: Int?
        /// Caminho da página "ver script", relativo ao endereço do agent-studio.
        public let url: String?

        enum CodingKeys: String, CodingKey {
            case id, title, runAs = "as", agent, host, instance, ageSeconds, url
        }
    }

    public struct Proposals: Decodable, Equatable {
        public let available: Bool
        public let total: Int?
        public let pending: [Proposal]
    }

    public struct Cost: Decodable, Equatable {
        public struct Agent: Decodable, Equatable {
            public let agent: String
            public let usd: Double?
            public let estimated: Bool?
            public let unpricedCalls: Int?
        }

        public let usd: Double?
        /// Parte do total é estimada pela tabela (chamada fora das assinaturas); o custo de lista calculado das
        /// assinaturas (#747) entra no total sem essa marca.
        public let estimated: Bool
        /// Chamadas sem preço na tabela: ficam fora do total.
        public let unpricedCalls: Int?
        public let agents: [Agent]
    }

    public struct Errors: Decodable, Equatable {
        public struct Row: Decodable, Equatable {
            public let host: String?
            public let agent: String?
            public let total: Int
        }

        public let total: Int
        public let rows: [Row]
    }

    /// Alerta do pipeline. `title` e `text` vêm prontos da API: o tray não repete a regra.
    public struct Alert: Decodable, Equatable {
        public let type: String?
        public let host: String?
        public let title: String?
        public let text: String?
    }

    /// Rodada do swarm parada esperando uma resposta do Bardi (#386).
    public struct Decision: Decodable, Equatable {
        public let round: String?
        /// Nome amigável da rodada (#605); ausente em rodada antiga e em agent-studio anterior à #605.
        public let name: String?
        public let host: String?
        public let question: String?
        public let ageSeconds: Int?
    }

    public struct Decisions: Decodable, Equatable {
        public let total: Int?
        public let pending: [Decision]
    }

    /// Etapa que o dispatcher publicou na página de uma rodada aberta, para o Bardi ler (#508). `title` é fixo por tipo e
    /// vem do agent-studio; o texto da etapa nunca vem aqui, só o caminho da página.
    public struct Step: Decodable, Equatable {
        public let round: String
        /// Nome amigável da rodada (#605); ausente em rodada antiga e em agent-studio anterior à #605.
        public let name: String?
        /// `triagem`, `merge`, `kaizen` ou `fechamento`.
        public let kind: String
        /// Número do PR, só na etapa `merge`.
        public let key: String?
        public let rev: Int
        /// `aprovado`, `reprovado` ou `sem-revisor`.
        public let review: String?
        public let title: String
        public let publishedAt: String?
        public let ageSeconds: Int?
        /// Caminho da página da rodada (com a âncora da etapa), relativo ao endereço do agent-studio.
        public let url: String?

        /// A etapa na revisão que o tray avisou: revisão nova da mesma etapa é texto novo, e avisa de novo.
        public var id: String { "\(round)|\(kind)|\(key ?? "")|\(rev)" }
    }

    public struct Steps: Decodable, Equatable {
        /// `false` = o agent-studio não leu o SurrealDB: nunca lista vazia por palpite.
        public let available: Bool
        public let total: Int?
        public let rows: [Step]
    }

    public let bar: Bar
    public let machines: [Machine]
    public let proposals: Proposals
    public let costToday: Cost
    public let errorsLastHour: Errors
    public let alerts: [Alert]
    /// Ausente em agent-studio anterior à #386.
    public let decisions: Decisions?
    /// Ausente em agent-studio anterior à #508.
    public let steps: Steps?

    public static func decode(_ data: Data) throws -> TraySnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TraySnapshot.self, from: data)
    }

    /// Os dois números da barra: pedidos pendentes e alertas.
    public var barTitle: String {
        "\(Self.count(bar.pending)) · \(Self.count(bar.alerts))"
    }

    private static func count(_ value: Int?) -> String {
        value.map(String.init) ?? "?"
    }
}
