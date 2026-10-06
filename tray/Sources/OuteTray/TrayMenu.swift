import AppKit
import SwiftUI
import TrayCore

/// O menu (#611): primeiro o que pede ação (pedidos, decisões do swarm, etapas das rodadas), depois uma linha de
/// resumo para máquinas, custo de hoje e erros da última hora, com o detalhe em submenu, e por fim os alertas (os
/// primeiros no menu, o resto em submenu). Os textos são do `MenuText`; o que vem da API entra como texto puro. Os
/// símbolos são do `MenuSymbol` (#473, Kubo): sem cor, com o âmbar só no pedido e na decisão pendentes.
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

    /// Linha de resumo com o detalhe em submenu; sem detalhe, é só a linha.
    @ViewBuilder
    private func summary(_ text: String, _ symbol: MenuSymbol, details: [String]) -> some View {
        if details.isEmpty {
            row(text, symbol)
        } else {
            Menu {
                ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                    Text(verbatim: detail)
                }
            } label: {
                MenuLabel(text, symbol)
            }
        }
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
            proposals(snapshot)
            decisions(snapshot)
            steps(snapshot)
            summaries(snapshot)
            alerts(snapshot)
        }
        Button { model.openStudio() } label: { MenuLabel("Abrir o agent-studio", .openStudio) }
        Button { Task { await model.refresh() } } label: { MenuLabel("Atualizar agora", .refresh) }
        Divider()
        // qual tray está instalado (#516): a versão e o commit que o `oute tray install` gravou no Info.plist
        row(AppVersion.line(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                            commit: Bundle.main.object(forInfoDictionaryKey: AppVersion.commitKey) as? String), .version)
        Button { NSApplication.shared.terminate(nil) } label: { MenuLabel("Sair do tray", .quit) }
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

    /// Etapas publicadas nas rodadas abertas (#508): cada linha abre a página da rodada na etapa. Lista vazia e lida não
    /// aparece; lista que o agent-studio não conseguiu ler aparece como indisponível.
    @ViewBuilder
    private func steps(_ snapshot: TraySnapshot) -> some View {
        if let steps = snapshot.steps, !steps.available || !steps.rows.isEmpty {
            row(MenuText.stepsHeader(steps), .steps)
            ForEach(Array(steps.rows.enumerated()), id: \.offset) { _, step in
                Button { model.openStep(step) } label: { MenuLabel(MenuText.step(step), .step) }
                    .disabled(model.stepURL(step) == nil)
            }
            Divider()
        }
    }

    /// Máquinas, custo e erros: uma linha cada, com o detalhe ao lado.
    @ViewBuilder
    private func summaries(_ snapshot: TraySnapshot) -> some View {
        summary(MenuText.machinesSummary(snapshot.machines), .machines, details: snapshot.machines.map(MenuText.machine))
        summary(MenuText.cost(snapshot.costToday), .cost, details: snapshot.costToday.agents.map(MenuText.agentCost))
        summary(MenuText.errors(snapshot.errorsLastHour), .errors, details: snapshot.errorsLastHour.rows.map(MenuText.errorRow))
        Divider()
    }

    @ViewBuilder
    private func alerts(_ snapshot: TraySnapshot) -> some View {
        let parts = MenuText.alertParts(snapshot.alerts)
        row(MenuText.alertsHeader(snapshot.alerts), .alerts)
        ForEach(Array(parts.shown.enumerated()), id: \.offset) { _, alert in
            Text(verbatim: MenuText.alert(alert))
        }
        if !parts.hidden.isEmpty {
            Menu(MenuText.moreAlerts(parts.hidden.count)) {
                ForEach(Array(parts.hidden.enumerated()), id: \.offset) { _, alert in
                    Text(verbatim: MenuText.alert(alert))
                }
            }
        }
        Divider()
    }
}
