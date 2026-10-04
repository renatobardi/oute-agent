/// Quais pedidos o tray já mostrou: a notificação do macOS sai só para id ainda não visto, e nunca na primeira
/// leitura (o que já estava pendente quando o tray abriu não é novidade).
public struct SeenProposals {
    private var seen: Set<String> = []
    private var primed = false

    public init() {}

    /// Os pedidos desta leitura que ainda não tinham aparecido. Leitura sem a lista de pedidos (SurrealDB fora)
    /// não conta: nem como primeira, nem para esquecer o que já foi visto.
    public mutating func newProposals(in snapshot: TraySnapshot) -> [TraySnapshot.Proposal] {
        guard snapshot.proposals.available else { return [] }
        let fresh = primed ? snapshot.proposals.pending.filter { !seen.contains($0.id) } : []
        seen.formUnion(snapshot.proposals.pending.map(\.id))
        primed = true
        return fresh
    }
}
