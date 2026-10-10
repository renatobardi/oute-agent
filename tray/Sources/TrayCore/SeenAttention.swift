/// Quais avisos de rodada o tray já mostrou (#776): a notificação do macOS sai uma vez por item, e nunca na primeira
/// leitura (o que já pedia atenção quando o tray abriu não é novidade). O item que deixa de valer sai da lista e sai
/// também do centro de notificações; o `id` é por ocorrência, então o mesmo fato que volta depois de resolvido é outro
/// item e avisa de novo.
public struct SeenAttention {
    public struct Change: Equatable {
        /// Itens que ainda não tinham aparecido.
        public let fresh: [TraySnapshot.Attention.Item]
        /// `id`s dos que estavam valendo na leitura anterior e não estão mais.
        public let resolved: [String]

        public init(fresh: [TraySnapshot.Attention.Item], resolved: [String]) {
            self.fresh = fresh
            self.resolved = resolved
        }
    }

    private var seen: Set<String> = []
    private var active: Set<String> = []
    private var primed = false

    public init() {}

    /// Leitura sem o bloco (agent-studio antigo) não conta: nem como primeira, nem para dar item por resolvido.
    public mutating func update(with snapshot: TraySnapshot) -> Change {
        guard let attention = snapshot.attention else { return Change(fresh: [], resolved: []) }
        let ids = Set(attention.rows.map(\.id))
        let fresh = primed ? attention.rows.filter { !seen.contains($0.id) } : []
        let resolved = primed ? active.subtracting(ids).sorted() : []
        seen.formUnion(ids)
        active = ids
        primed = true
        return Change(fresh: fresh, resolved: resolved)
    }
}
