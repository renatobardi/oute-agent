/// O comando que o "Aprovar…/Recusar…" abre no Terminal. O tray não decide nada: quem lê o script e confirma é
/// o Bardi, no `oute approve <id>` (ADR-08 §10; o ADR-01 não muda).
public enum ApproveCommand {
    /// `nil` = item desabilitado: id fora do formato ou host que não está na tabela local.
    public static func command(for proposal: TraySnapshot.Proposal, hosts: TrayHosts) -> String? {
        guard ProposalID.isValid(proposal.id), let host = proposal.host,
              let target = hosts.target(for: host) else { return nil }
        let approve = "oute approve \(proposal.id)"
        switch target {
        case .local: return approve
        case .ssh(let alias): return "ssh -t \(alias) 'bash -lc \"\(approve)\"'"
        }
    }
}
