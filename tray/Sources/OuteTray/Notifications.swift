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

    func post(id: String, title: String, body: String, kind: String = "pedido") {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // a sakura vai anexada na própria notificação (#563): o ícone do app o macOS guarda por conta dele e
        // pode seguir mostrando o genérico; a imagem anexada aparece sempre
        if let image = SakuraIcon.notificationImage() {
            if let attachment = try? UNNotificationAttachment(identifier: "sakura", url: image, options: nil) {
                content.attachments = [attachment]
            } else {
                try? FileManager.default.removeItem(at: image)
            }
        }
        center.add(UNNotificationRequest(identifier: "\(kind)-\(id)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
