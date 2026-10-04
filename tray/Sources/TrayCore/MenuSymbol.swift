import Foundation

/// O símbolo de cada linha do menu (#473, Kubo): SF Symbols monocromáticos, na cor do sistema. O âmbar do Gate
/// fica só no que espera o Bardi: pedido pendente e decisão pendente. Erro e alerta usam o mesmo símbolo, sem cor.
public enum MenuSymbol: CaseIterable {
    public enum Tint {
        /// Template: o sistema pinta (claro, escuro, item desabilitado).
        case mono
        /// O âmbar do Kubo (`--gate`).
        case gate
    }

    case bar
    case notice
    case machines
    case proposals
    case pendingProposal
    case decisions
    case pendingDecision
    case cost
    case errors
    case alerts
    case viewScript
    case approve
    case refuse
    case openStudio
    case refresh
    case quit

    public var systemName: String {
        switch self {
        case .bar: return "tray.full"
        case .notice, .errors, .alerts: return "exclamationmark.triangle"
        case .machines: return "desktopcomputer"
        case .proposals: return "tray"
        case .pendingProposal, .pendingDecision: return "hand.raised"
        case .decisions: return "questionmark.bubble"
        case .cost: return "dollarsign.circle"
        case .viewScript: return "doc.text"
        case .approve: return "checkmark"
        case .refuse: return "xmark"
        case .openStudio: return "arrow.up.right.square"
        case .refresh: return "arrow.clockwise"
        case .quit: return "power"
        }
    }

    public var tint: Tint {
        switch self {
        case .pendingProposal, .pendingDecision: return .gate
        default: return .mono
        }
    }
}
