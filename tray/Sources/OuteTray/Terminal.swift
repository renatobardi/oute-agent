import AppKit
import Foundation

/// Abre o Terminal num comando, por um arquivo `.command` só do usuário (0700, em pasta temporária própria). O
/// comando vem do `ApproveCommand`, com o id já validado e o alias da tabela local: nada do texto da API chega aqui.
enum Terminal {
    static func open(command: String) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("oute-tray-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("oute-approve.command")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "#!/bin/sh\nrm -f \"$0\"\n\(command)\n".write(to: file, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(file)
    }
}
