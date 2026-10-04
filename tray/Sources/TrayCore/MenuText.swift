import Foundation

/// O texto de cada linha do menu. Tudo vem pronto da API; aqui só se junta (o tray não repete regra do agent-studio).
public enum MenuText {
    public static func machine(_ machine: TraySnapshot.Machine) -> String {
        let state: String
        switch machine.state {
        case "active": state = "ativa"
        case "stopped": state = "parada"
        default: state = machine.state
        }
        let last = machine.idleSeconds.map { "último dado \(Age.text(seconds: $0))" } ?? "sem dado"
        return join([machine.host, state, last])
    }

    public static func proposalsHeader(_ proposals: TraySnapshot.Proposals) -> String {
        guard proposals.available else { return "Pedidos pendentes: ? (estado indisponível)" }
        return "Pedidos pendentes: \(proposals.total ?? proposals.pending.count)"
    }

    public static func proposal(_ proposal: TraySnapshot.Proposal) -> String {
        join([proposal.title ?? proposal.id, proposal.runAs, proposal.agent, proposal.host,
              proposal.ageSeconds.map(Age.text(seconds:))])
    }

    public static func decision(_ decision: TraySnapshot.Decision) -> String {
        join([decision.round, decision.question, decision.ageSeconds.map(Age.text(seconds:))])
    }

    public static func cost(_ cost: TraySnapshot.Cost) -> String {
        "Custo de hoje: " + amount(cost.usd, estimated: cost.estimated, unpricedCalls: cost.unpricedCalls)
    }

    public static func agentCost(_ agent: TraySnapshot.Cost.Agent) -> String {
        "\(agent.agent): " + amount(agent.usd, estimated: agent.estimated ?? false, unpricedCalls: agent.unpricedCalls)
    }

    public static func errors(_ errors: TraySnapshot.Errors) -> String {
        "Erros na última hora: \(errors.total)"
    }

    public static func errorRow(_ row: TraySnapshot.Errors.Row) -> String {
        "\(join([row.host, row.agent])): \(row.total)"
    }

    public static func alert(_ alert: TraySnapshot.Alert) -> String {
        let title = alert.title ?? alert.type ?? "alerta"
        return join([alert.text.map { "\(title): \($0)" } ?? title, alert.host])
    }

    /// "US$ 5,54", com o estimado marcado e as chamadas sem preço à vista (elas ficam fora do total).
    private static func amount(_ usd: Double?, estimated: Bool, unpricedCalls: Int?) -> String {
        var text = "US$ " + (usd.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "?")
        if estimated { text += " (estimado)" }
        if let calls = unpricedCalls, calls > 0 {
            text += " · \(calls) \(calls == 1 ? "chamada" : "chamadas") sem preço"
        }
        return text
    }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
