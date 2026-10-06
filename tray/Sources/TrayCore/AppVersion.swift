import Foundation

/// A linha do menu que diz qual tray está instalado (#516): a versão e o commit que o `oute tray install` grava no
/// `Info.plist` (`CFBundleShortVersionString` e `OuteTrayCommit`). Binário rodado fora do `.app` não tem nenhum dos dois.
public enum AppVersion {
    /// A chave do `Info.plist` com o commit do repo na hora do install.
    public static let commitKey = "OuteTrayCommit"

    public static func line(version: String?, commit: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commit = commit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return "OuteTray (fora do .app: sem versão)" }
        return commit.isEmpty ? "OuteTray \(version)" : "OuteTray \(version) (\(commit))"
    }
}
