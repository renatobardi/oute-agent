import AppKit
import SwiftUI
import TrayCore

/// O menu: máquinas, pedidos, decisões do swarm, custo de hoje, erros da última hora e alertas. Os textos são do
/// `MenuText`; o que vem da API entra como texto puro. Os símbolos são do `MenuSymbol` (#473, Kubo): sem cor, com
/// o âmbar só no pedido e na decisão pendentes.
struct TrayMenu: View {
    @ObservedObject var model: TrayModel

    var body: some View {
        // no menu do macOS o `Label` mostra só o título, a não ser com este estilo
        Group { content }.labelStyle(.titleAndIcon)
    }

    /// Linha só de leitura com símbolo: botão desabilitado, que o menu desenha com a imagem.
    private func row(_ text: String, _ symbol: MenuSymbol) -> some View {
        Button {} label: { MenuLabel(text, symbol) }.disabled(true)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.configError {
            row(error, .notice)
            Divider()
        }
        if let notice = model.reading.notice(now: Date()) {
            row(notice, .notice)
            Divider()
        }
        if let snapshot = model.reading.snapshot {
            machines(snapshot)
            proposals(snapshot)
            decisions(snapshot)
            cost(snapshot)
            errorsAndAlerts(snapshot)
        }
        Button { model.openStudio() } label: { MenuLabel("Abrir o agent-studio", .openStudio) }
        Button { Task { await model.refresh() } } label: { MenuLabel("Atualizar agora", .refresh) }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { MenuLabel("Sair do tray", .quit) }
    }

    @ViewBuilder
    private func machines(_ snapshot: TraySnapshot) -> some View {
        row("Máquinas", .machines)
        ForEach(Array(snapshot.machines.enumerated()), id: \.offset) { _, machine in
            Text(MenuText.machine(machine))
        }
        Divider()
    }

    @ViewBuilder
    private func proposals(_ snapshot: TraySnapshot) -> some View {
        row(MenuText.proposalsHeader(snapshot.proposals), .proposals)
        ForEach(Array(snapshot.proposals.pending.enumerated()), id: \.offset) { _, proposal in
            Menu {
                Button { model.openScript(proposal) } label: { MenuLabel("Ver script", .viewScript) }
                    .disabled(model.scriptURL(proposal) == nil)
                // os dois abrem o mesmo `oute approve <id>`: é lá que o Bardi lê o script e decide
                Button { model.openApprove(proposal) } label: { MenuLabel("Aprovar…", .approve) }
                    .disabled(model.approveCommand(proposal) == nil)
                Button { model.openApprove(proposal) } label: { MenuLabel("Recusar…", .refuse) }
                    .disabled(model.approveCommand(proposal) == nil)
            } label: {
                MenuLabel(MenuText.proposal(proposal), .pendingProposal)
            }
        }
        Divider()
    }

    @ViewBuilder
    private func decisions(_ snapshot: TraySnapshot) -> some View {
        if let decisions = snapshot.decisions, !decisions.pending.isEmpty {
            row("Decisões pendentes do swarm: \(decisions.pending.count)", .decisions)
            ForEach(Array(decisions.pending.enumerated()), id: \.offset) { _, decision in
                row(MenuText.decision(decision), .pendingDecision)
            }
            Divider()
        }
    }

    @ViewBuilder
    private func cost(_ snapshot: TraySnapshot) -> some View {
        row(MenuText.cost(snapshot.costToday), .cost)
        ForEach(Array(snapshot.costToday.agents.enumerated()), id: \.offset) { _, agent in
            Text(MenuText.agentCost(agent))
        }
        Divider()
    }

    @ViewBuilder
    private func errorsAndAlerts(_ snapshot: TraySnapshot) -> some View {
        row(MenuText.errors(snapshot.errorsLastHour), .errors)
        ForEach(Array(snapshot.errorsLastHour.rows.enumerated()), id: \.offset) { _, row in
            Text(MenuText.errorRow(row))
        }
        Divider()
        row("Alertas: \(snapshot.alerts.count)", .alerts)
        ForEach(Array(snapshot.alerts.enumerated()), id: \.offset) { _, alert in
            Text(MenuText.alert(alert))
        }
        Divider()
    }
}
