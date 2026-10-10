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

    /// A linha de resumo das máquinas (#611): o detalhe de cada uma fica no submenu.
    public static func machinesSummary(_ machines: [TraySnapshot.Machine]) -> String {
        guard !machines.isEmpty else { return "Máquinas: nenhuma" }
        let active = machines.filter { $0.state == "active" }.count
        if active == machines.count { return "Máquinas: \(active) \(active == 1 ? "ativa" : "ativas")" }
        return "Máquinas: \(active) de \(machines.count) \(machines.count == 1 ? "ativa" : "ativas")"
    }

    public static func proposalsHeader(_ proposals: TraySnapshot.Proposals) -> String {
        guard proposals.available else { return "Pedidos pendentes: ? (estado indisponível)" }
        return "Pedidos pendentes: \(proposals.total ?? proposals.pending.count)"
    }

    public static func proposal(_ proposal: TraySnapshot.Proposal) -> String {
        join([proposal.title ?? proposal.id, proposal.runAs, proposal.agent, proposal.host,
              proposal.ageSeconds.map(Age.text(seconds:))])
    }

    public static func stepsHeader(_ steps: TraySnapshot.Steps) -> String {
        guard steps.available else { return "Etapas das rodadas: ? (estado indisponível)" }
        return "Etapas das rodadas abertas: \(steps.total ?? steps.rows.count)"
    }

    /// "Pedido de merge #12 · swarm-1003-1211 · sem revisor · há 5 min": o título é o fixo da API, e o veredito só
    /// aparece quando a etapa não foi aprovada.
    public static func step(_ step: TraySnapshot.Step) -> String {
        let review: String?
        switch step.review {
        case "reprovado": review = "reprovada pelo revisor"
        case "sem-revisor": review = "sem revisor"
        default: review = nil
        }
        return join([step.title, roundLabel(step.round, name: step.name), review, step.ageSeconds.map(Age.text(seconds:))])
    }

    public static func attentionHeader(_ attention: TraySnapshot.Attention) -> String {
        "Avisos das rodadas: \(attention.total ?? attention.rows.count)"
    }

    /// "CI reprovado no PR #13 · Brave_Otter (swarm-1003-1211) · há 20 min": título fixo da API, rodada e idade.
    public static func attention(_ item: TraySnapshot.Attention.Item) -> String {
        join([item.title, roundLabel(item.round, name: item.name), item.ageSeconds.map(Age.text(seconds:))])
    }

    /// O corpo da notificação do macOS: o título do item já vai como título dela.
    public static func attentionBody(_ item: TraySnapshot.Attention.Item) -> String {
        join([roundLabel(item.round, name: item.name), item.ageSeconds.map(Age.text(seconds:))])
    }

    public static func decision(_ decision: TraySnapshot.Decision) -> String {
        join([decision.round.map { roundLabel($0, name: decision.name) }, decision.question, decision.ageSeconds.map(Age.text(seconds:))])
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

    /// Quantos alertas o menu principal mostra (#611); o resto vai para o submenu.
    public static let alertLimit = 3

    public static func alertsHeader(_ alerts: [TraySnapshot.Alert]) -> String {
        "Alertas: \(alerts.count)"
    }

    /// Os primeiros `alertLimit` alertas, na ordem da API, e os que sobram.
    public static func alertParts(_ alerts: [TraySnapshot.Alert]) -> (shown: [TraySnapshot.Alert], hidden: [TraySnapshot.Alert]) {
        (Array(alerts.prefix(alertLimit)), Array(alerts.dropFirst(alertLimit)))
    }

    public static func moreAlerts(_ count: Int) -> String {
        "mais \(count) \(count == 1 ? "alerta" : "alertas")…"
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

    /// "Brave_Otter (swarm-1005-1258)": o nome amigável junto do id técnico (#605); rodada sem nome, só o id.
    private static func roundLabel(_ round: String, name: String?) -> String {
        guard let name = name, !name.isEmpty else { return round }
        return "\(name) (\(round))"
    }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
