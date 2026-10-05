# O `claude` falso do revisor das etapas (#507; usado também pelo tema ciclo, #509). Para `source` depois do swarm.sh (precisa de $TMP).
# `claude` falso do revisor: grava argumentos, ambiente e stdin (o prompt) em $FAKE/rev/*.<n> e devolve o JSON do
# `claude -p --output-format json` com o texto de $FAKE/rev/answer; $FAKE/rev/sleep dorme, $FAKE/rev/rc sai com erro
RBIN="$TMP/rbin"; mkdir -p "$RBIN"
cat > "$RBIN/claude" <<'SH'
#!/usr/bin/env bash
d="$FAKE/rev"; mkdir -p "$d"
i=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$d/n"
printf "%s\n" "$@" > "$d/args.$i"; env > "$d/env.$i"; pwd -P > "$d/pwd.$i"; stat -c %a "$(dirname "$PWD")" > "$d/perm.$i"; cat > "$d/stdin.$i"
[[ ! -f "$d/mutate" ]] || printf 'texto trocado durante o review' > "$(cat "$d/mutate")"
[[ ! -f "$d/sleep" ]] || /bin/sleep "$(cat "$d/sleep")"
[[ ! -f "$d/rc" ]] || exit "$(cat "$d/rc")"
jq -cn --rawfile r "$d/answer" --argjson c "$(cat "$d/cost" 2>/dev/null || echo 0.0123)" '{type: "result", result: $r, total_cost_usd: $c, is_error: false}'
SH
chmod +x "$RBIN/claude"
