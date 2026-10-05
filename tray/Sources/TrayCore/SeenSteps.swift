/// Quais etapas de rodada o tray já mostrou: a notificação do macOS sai só para etapa ainda não vista, e nunca na
/// primeira leitura (o que já estava publicado quando o tray abriu não é novidade).
public struct SeenSteps {
    private var seen: Set<String> = []
    private var primed = false

    public init() {}

    /// As etapas desta leitura que ainda não tinham aparecido. Leitura sem o bloco (agent-studio antigo) ou com ele
    /// indisponível (SurrealDB fora) não conta: nem como primeira, nem para esquecer o que já foi visto.
    public mutating func newSteps(in snapshot: TraySnapshot) -> [TraySnapshot.Step] {
        guard let steps = snapshot.steps, steps.available else { return [] }
        let fresh = primed ? steps.rows.filter { !seen.contains($0.id) } : []
        seen.formUnion(steps.rows.map(\.id))
        primed = true
        return fresh
    }
}
