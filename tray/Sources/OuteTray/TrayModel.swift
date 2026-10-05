import AppKit
import Foundation
import TrayCore
import UserNotifications

/// Lê o `/v1/tray` a cada 15 s e guarda o que o menu mostra. Só `GET`, com a credencial de leitura.
@MainActor
final class TrayModel: ObservableObject {
    static let interval: TimeInterval = 15

    @Published private(set) var reading = TrayReading()
    /// Por que o tray não consegue ler (token ausente, endereço inválido). Nunca leva o valor do token.
    let configError: String?

    private let config: TrayConfig?
    private let hosts: TrayHosts
    private let session: URLSession
    private let notifications = Notifications()
    private var seen = SeenProposals()
    private var seenSteps = SeenSteps()
    private var timer: Timer?

    init() {
        // a cada início: token do ~/.oute/agent.env (nunca copiado) e a tabela local de hosts
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".oute")
        let agentEnv = (try? String(contentsOf: home.appendingPathComponent("agent.env"), encoding: .utf8)) ?? ""
        hosts = TrayHosts(text: (try? String(contentsOf: home.appendingPathComponent("tray-hosts"), encoding: .utf8)) ?? "")
        do {
            config = try TrayConfig.load(agentEnv: agentEnv, environment: ProcessInfo.processInfo.environment)
            configError = nil
        } catch let error as TrayConfig.LoadError {
            config = nil
            configError = error.message
        } catch {
            config = nil
            configError = "configuração do tray ilegível"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)

        notifications.start()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let config else { return }
        var request = URLRequest(url: config.trayURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.readToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, response) = try await session.data(for: request)
            reading.received(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body, at: Date())
        } catch {
            reading.failed()
        }
        guard !reading.failing, let snapshot = reading.snapshot else { return }
        for proposal in seen.newProposals(in: snapshot) {
            notifications.post(id: proposal.id, title: "Pedido novo no canal de aprovação", body: MenuText.proposal(proposal))
        }
        for step in seenSteps.newSteps(in: snapshot) {
            notifications.post(id: step.id, title: "Etapa nova na página da rodada", body: MenuText.step(step), kind: "etapa")
        }
    }

    // MARK: - o que o menu abre (o tray não decide nada)

    func scriptURL(_ proposal: TraySnapshot.Proposal) -> URL? {
        config?.pageURL(path: proposal.url)
    }

    func approveCommand(_ proposal: TraySnapshot.Proposal) -> String? {
        ApproveCommand.command(for: proposal, hosts: hosts)
    }

    func stepURL(_ step: TraySnapshot.Step) -> URL? {
        config?.pageURL(path: step.url)
    }

    func openStep(_ step: TraySnapshot.Step) {
        if let url = stepURL(step) { NSWorkspace.shared.open(url) }
    }

    func openScript(_ proposal: TraySnapshot.Proposal) {
        if let url = scriptURL(proposal) { NSWorkspace.shared.open(url) }
    }

    func openApprove(_ proposal: TraySnapshot.Proposal) {
        if let command = approveCommand(proposal) { Terminal.open(command: command) }
    }

    func openStudio() {
        if let url = config?.pageURL(path: "/") ?? URL(string: TrayConfig.defaultBaseURL) { NSWorkspace.shared.open(url) }
    }
}

/// A credencial de leitura vai no cabeçalho: redirecionamento não é seguido (a resposta 3xx conta como falha).
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
