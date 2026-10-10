import AppKit
import Foundation
import UserNotifications

/// Notificação do macOS de pedido novo e de etapa nova de rodada (#508). Só funciona dentro do `.app` (o `oute tray install` monta): rodando o
/// binário solto não há pacote, e o centro de notificações não existe.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, kind: String = "pedido", url: URL? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // o clique abre a página da rodada (#776); o endereço sai do `TrayConfig.pageURL`, nunca do texto da API
        if let url { content.userInfo = ["url": url.absoluteString] }
        center.add(UNNotificationRequest(identifier: "\(kind)-\(id)", content: content, trigger: nil))
    }

    /// O aviso deixou de valer: sai do centro de notificações junto com a linha do menu.
    func remove(ids: [String], kind: String) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids.map { "\(kind)-\($0)" })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let text = response.notification.request.content.userInfo["url"] as? String
        if let text, let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
