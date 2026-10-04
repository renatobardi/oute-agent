import AppKit
import SwiftUI
import TrayCore

/// O menu: máquinas, pedidos, decisões do swarm, custo de hoje, erros da última hora e alertas. Os textos são do
/// `MenuText`; o que vem da API entra como texto puro.
struct TrayMenu: View {
    @ObservedObject var model: TrayModel

    var body: some View {
        if let error = model.configError {
            Text(error)
            Divider()
        }
        if let notice = model.reading.notice(now: Date()) {
            Text(notice)
            Divider()
        }
        if let snapshot = model.reading.snapshot {
            machines(snapshot)
            proposals(snapshot)
            decisions(snapshot)
            cost(snapshot)
            errorsAndAlerts(snapshot)
        }
        Button("Abrir o agent-studio") { model.openStudio() }
        Button("Atualizar agora") { Task { await model.refresh() } }
        Divider()
        Button("Sair do tray") { NSApplication.shared.terminate(nil) }
    }

    @ViewBuilder
    private func machines(_ snapshot: TraySnapshot) -> some View {
        Text("Máquinas")
        ForEach(Array(snapshot.machines.enumerated()), id: \.offset) { _, machine in
            Text(MenuText.machine(machine))
        }
        Divider()
    }

    @ViewBuilder
    private func proposals(_ snapshot: TraySnapshot) -> some View {
        Text(MenuText.proposalsHeader(snapshot.proposals))
        ForEach(Array(snapshot.proposals.pending.enumerated()), id: \.offset) { _, proposal in
            Menu(MenuText.proposal(proposal)) {
                Button("Ver script") { model.openScript(proposal) }
                    .disabled(model.scriptURL(proposal) == nil)
                // os dois abrem o mesmo `oute approve <id>`: é lá que o Bardi lê o script e decide
                Button("Aprovar…") { model.openApprove(proposal) }
                    .disabled(model.approveCommand(proposal) == nil)
                Button("Recusar…") { model.openApprove(proposal) }
                    .disabled(model.approveCommand(proposal) == nil)
            }
        }
        Divider()
    }

    @ViewBuilder
    private func decisions(_ snapshot: TraySnapshot) -> some View {
        if let decisions = snapshot.decisions, !decisions.pending.isEmpty {
            Text("Decisões pendentes do swarm: \(decisions.pending.count)")
            ForEach(Array(decisions.pending.enumerated()), id: \.offset) { _, decision in
                Text(MenuText.decision(decision))
            }
            Divider()
        }
    }

    @ViewBuilder
    private func cost(_ snapshot: TraySnapshot) -> some View {
        Text(MenuText.cost(snapshot.costToday))
        ForEach(Array(snapshot.costToday.agents.enumerated()), id: \.offset) { _, agent in
            Text(MenuText.agentCost(agent))
        }
        Divider()
    }

    @ViewBuilder
    private func errorsAndAlerts(_ snapshot: TraySnapshot) -> some View {
        Text(MenuText.errors(snapshot.errorsLastHour))
        ForEach(Array(snapshot.errorsLastHour.rows.enumerated()), id: \.offset) { _, row in
            Text(MenuText.errorRow(row))
        }
        Divider()
        Text("Alertas: \(snapshot.alerts.count)")
        ForEach(Array(snapshot.alerts.enumerated()), id: \.offset) { _, alert in
            Text(MenuText.alert(alert))
        }
        Divider()
    }
}
