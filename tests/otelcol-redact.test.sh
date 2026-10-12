#!/usr/bin/env bash
# Filtro de segredo do collector (ADR-04, adendo): roda o config/otel/collector.yaml de verdade contra um S3 falso e
# confere o que chega ao bucket. Cada caso manda um texto com uma credencial conhecida (gerada na hora, nunca literal)
# e espera o texto exato com [redigido] no lugar; texto sem segredo sai igual; nenhum registro some (mascarar, não
# apagar). Log (corpo e atributo) e span (atributo e evento). Sem Docker: usa o otelcol-contrib do PATH se for a versão
# do compose, senão baixa o binário fixado (tests/lib/otelcol.sh). Precisa de python3, jq e curl.
# Uso: tests/otelcol-redact.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"   # closed_port
CPID=""; S3PID=""
cleanup() { for p in $CPID $S3PID; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "${TMP:?}"; return 0; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, otelcol_env, otelcol_s3_start, otelcol_start, jqp…
otelcol_bin
check "otelcol-contrib $V"                              otelcol_version_ok
otelcol_env
CFG="$ROOT/config/otel/collector.yaml"
export AGENT_STUDIO_INGEST_TOKEN="$(python3 -c "import secrets; print(secrets.token_hex(16))")" AGENT_STUDIO_URL=https://studio.invalid
check "validate collector.yaml + agent-studio.yaml"     "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/agent-studio.yaml"
P="$(otelcol_print --config="$CFG" --config="$ROOT/config/otel/agent-studio.yaml")"
check "transform/redact nos pipelines de logs e traces (bucket e agent-studio)" jqp '
  [.service.pipelines | to_entries[] | select(.key | test("^(logs|traces)/")) | .value.processors | index("transform/redact")]
  | all(. != null)'

# ---------------------------------------------------------------- collector de teste: mesmo config, portas locais, S3 falso
S3D="$TMP/s3"; otelcol_s3_start "$S3D" ok
otelcol_ports
{ otelcol_test_yaml s3; cat <<EOF; } > "$TMP/test.yaml"
service:
  telemetry: {metrics: {level: none}}
EOF
start() { otelcol_start --config="$CFG" --config="$TMP/test.yaml"; return $?; }
start || die "collector"

# casos: gerados e enviados por este script; o esperado e os segredos ficam em $TMP (apagado no fim)
RUN="redact-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
SCHEME=http
cat > "$TMP/redact.py" <<'PY'
# gen <casos.json> <run>: os casos (segredo gerado, texto com ele, texto esperado). send <base> <casos.json>: manda
# os logs e os spans por OTLP/HTTP JSON. ready <casos.json> <objects.jsonl>: 0 quando todos os casos chegaram ao S3.
# check <casos.json> <objects.jsonl>: um "ok   …" ou "FAIL …" por conferência (sem imprimir valor de segredo).
import json, secrets, string, sys, time, urllib.request
A = string.ascii_letters + string.digits
UP = string.ascii_uppercase + string.digits

def rnd(n, alpha=A):
    return ''.join(secrets.choice(alpha) for _ in range(n))

def gen(path, run):
    gh, gh2, ghpat, sk = 'ghp_' + rnd(36), 'gho_' + rnd(36), 'github_pat_' + rnd(40, A + '_'), 'sk-ant-' + rnd(40, A + '_-')
    bearer, env, envq, envesc, span = (rnd(32) for _ in range(5))
    spanev = 'ghp_' + rnd(36)
    aws, pem, env2 = 'AKIA' + rnd(16, UP), rnd(64), rnd(32)
    asia, xox, jwt = 'ASIA' + rnd(16, UP), 'xoxb-' + rnd(24), 'eyJ' + rnd(20) + '.eyJ' + rnd(20) + '.' + rnd(20)
    basic, uuser, upass = rnd(20), rnd(8), rnd(20)
    low, pw, sp, bs = rnd(32), rnd(24), rnd(32), rnd(8) + '\\'
    pem_trunc = '-----BEGIN OPENSSH PRIVATE KEY-----\\n' + rnd(40)
    pgp = '-----BEGIN PGP PRIVATE KEY BLOCK-----\\n' + rnd(40) + '\\n-----END PGP PRIVATE KEY BLOCK-----'
    pem_txt = '-----BEGIN OPENSSH PRIVATE KEY-----\\n' + pem + '\\n-----END OPENSSH PRIVATE KEY-----'
    limpo = 'ls -la /workspace && echo ok'
    # (caso, campo, origem, texto de entrada, texto esperado, segredos que não podem sair)
    logs = [
        ('ghp', 'conteudo', f'token {gh} usado', 'token [redigido] usado', [gh]),
        ('gho-corpo', 'corpo', f'corpo {gh2}', 'corpo [redigido]', [gh2]),
        ('env-corpo', 'corpo', f'ZAI_API_KEY={env2} fim', 'ZAI_API_KEY=[redigido] fim', [env2]),
        ('github-pat', 'conteudo', f'pat {ghpat} no log', 'pat [redigido] no log', [ghpat]),
        ('sk', 'conteudo', f'chave {sk}', 'chave [redigido]', [sk]),
        ('bearer', 'conteudo', f'Authorization: Bearer {bearer}', 'Authorization: Bearer [redigido]', [bearer]),
        ('env', 'conteudo', f'ZAI_API_KEY={env} ls', 'ZAI_API_KEY=[redigido] ls', [env]),
        ('env-aspas', 'conteudo', f'declare -x OUTE_TESTE_TOKEN="{envq}"', 'declare -x OUTE_TESTE_TOKEN=[redigido]', [envq]),
        ('env-escapada', 'conteudo', 'OUTE_TESTE_SECRET=\\"' + envesc + '\\" fim', 'OUTE_TESTE_SECRET=[redigido] fim', [envesc]),
        ('pem', 'conteudo', 'chave: ' + pem_txt + ' fim', 'chave: [redigido] fim', [pem]),
        ('aws', 'conteudo', f'id {aws}', 'id [redigido]', [aws]),
        ('limpo', 'conteudo', limpo, limpo, []),
        ('quase', 'conteudo', 'risk-management task-123 ghost_mode=1 sk-curto', 'risk-management task-123 ghost_mode=1 sk-curto', []),
        ('nome-sem-segredo', 'conteudo', 'NOME_SEM_SEGREDO=valor-visivel', 'NOME_SEM_SEGREDO=valor-visivel', []),
        ('quase-prosa', 'conteudo', 'the key: value, max_tokens=4096', 'the key: value, max_tokens=4096', []),
        ('pem-truncado', 'conteudo', 'chave ' + pem_trunc, 'chave [redigido]', [pem_trunc.split('\\n')[1]]),
        ('pgp', 'conteudo', pgp, '[redigido]', [pgp.split('\\n')[1]]),
        ('slack', 'conteudo', f'slack {xox}', 'slack [redigido]', [xox]),
        ('asia', 'conteudo', f'id {asia}', 'id [redigido]', [asia]),
        ('jwt', 'conteudo', f'token {jwt}', 'token [redigido]', [jwt]),
        ('basic', 'conteudo', f'Authorization: Basic {basic}', 'Authorization: Basic [redigido]', [basic]),
        ('url-senha', 'conteudo', f'git clone https://{uuser}:{upass}@host/x', 'git clone https://[redigido]@host/x', [upass]),
        ('minuscula', 'conteudo', f'api_key={low} ok', 'api_key=[redigido] ok', [low]),
        ('json-senha', 'conteudo', '{"password": "' + pw + '"}', '{password=[redigido]}', [pw]),
        ('espaco-igual', 'conteudo', f'OPENAI_API_KEY = {sp} fim', 'OPENAI_API_KEY=[redigido] fim', [sp]),
        ('barra-invertida', 'conteudo', f'NOME_TOKEN={bs}cd fim', 'NOME_TOKEN=[redigido] fim', [bs.rstrip('\\')]),
    ]
    spans = [
        ('span-env', 'conteudo', f'export OUTE_TESTE_KEY={span}', 'export OUTE_TESTE_KEY=[redigido]', [span]),
        ('span-evento', 'conteudo', f'evento {spanev}', 'evento [redigido]', [spanev]),
        ('span-limpo', 'conteudo', 'sem segredo no span', 'sem segredo no span', []),
    ]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump({'run': run, 'logs': logs, 'spans': spans}, f)

def attr(k, v):
    return {'key': k, 'value': {'stringValue': v}}

def send(base, path):
    d = json.load(open(path, encoding='utf-8'))
    res = {'attributes': [attr('service.name', 'otelcol-redact-test')]}
    now = str(time.time_ns())
    logs = [{'timeUnixNano': now, 'body': {'stringValue': 'evento-' + c},
             'attributes': [attr('oute.teste.run', d['run']), attr('oute.teste.caso', c), attr(campo, origem)]}
            for c, campo, origem, _, _ in d['logs'] if campo == 'conteudo'] + \
           [{'timeUnixNano': now, 'body': {'stringValue': origem},
             'attributes': [attr('oute.teste.run', d['run']), attr('oute.teste.caso', c)]}
            for c, campo, origem, _, _ in d['logs'] if campo == 'corpo']
    spans = []
    for i, (c, campo, origem, _, _) in enumerate(d['spans']):
        ev = [{'name': 'evento', 'timeUnixNano': now, 'attributes': [attr(campo, origem)]}] if c == 'span-evento' else []
        spans.append({'traceId': '%032x' % (secrets.randbits(128) | 1), 'spanId': '%016x' % (secrets.randbits(64) | 1),
                      'name': 'teste-redact', 'kind': 1, 'startTimeUnixNano': now, 'endTimeUnixNano': now,
                      'attributes': [attr('oute.teste.run', d['run']), attr('oute.teste.caso', c)] +
                                    ([] if ev else [attr(campo, origem)]), 'events': ev})
    for sig, body in (('logs', {'resourceLogs': [{'resource': res, 'scopeLogs': [{'logRecords': logs}]}]}),
                      ('traces', {'resourceSpans': [{'resource': res, 'scopeSpans': [{'spans': spans}]}]})):
        req = urllib.request.Request(f'{base}/v1/{sig}', json.dumps(body).encode(), {'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=10).read()

def records(objects):
    # {caso: {'attrs': {chave: valor}, 'body': texto}} de cada objeto do S3 falso (OTLP-JSON por linha)
    out = {}
    for line in open(objects, encoding='utf-8'):
        o = json.loads(line)['otlp']
        for r in o.get('resourceLogs', []):
            for s in r.get('scopeLogs', []):
                for x in s.get('logRecords', []):
                    a = {y['key']: y['value'].get('stringValue') for y in x.get('attributes', [])}
                    if 'oute.teste.caso' in a:
                        out[a['oute.teste.caso']] = {'attrs': a, 'body': x.get('body', {}).get('stringValue')}
        for r in o.get('resourceSpans', []):
            for s in r.get('scopeSpans', []):
                for x in s.get('spans', []):
                    a = {y['key']: y['value'].get('stringValue') for y in x.get('attributes', [])}
                    if 'oute.teste.caso' in a:
                        ev = {y['key']: y['value'].get('stringValue') for e in x.get('events', [])
                              for y in e.get('attributes', [])}
                        out[a['oute.teste.caso']] = {'attrs': {**a, **ev}, 'body': None}
    return out

def ready(casos, objects):
    d = json.load(open(casos, encoding='utf-8'))
    try:
        got = records(objects)
    except (OSError, ValueError):
        return 1
    want = [c for c, *_ in d['logs'] + d['spans']]
    return 0 if all(c in got for c in want) else 1

def check(casos, objects):
    d = json.load(open(casos, encoding='utf-8'))
    raw = open(objects, encoding='utf-8').read()
    got = records(objects)
    for c, campo, _, esperado, segredos in d['logs'] + d['spans']:
        r = got.get(c)
        if r is None:
            print(f'FAIL {c}: o registro não chegou ao bucket'); continue
        valor = r['body'] if campo == 'corpo' else r['attrs'].get(campo)
        if valor == esperado:
            print(f'ok   {c}: mascarado como o esperado, registro presente')
        else:
            print(f'FAIL {c}: o texto no bucket não é o esperado')
        for s in segredos:
            if s in raw:
                print(f'FAIL {c}: o segredo gerado saiu no bucket')
            else:
                print(f'ok   {c}: o segredo gerado não está no bucket')
    n_log = len(d['logs']); n_span = len(d['spans'])
    got_run = [c for c in got if c in {x[0] for x in d['logs'] + d['spans']}]
    print(f'ok   nenhum registro some: {len(got_run)} de {n_log + n_span}' if len(got_run) == n_log + n_span
          else f'FAIL registros: {len(got_run)} de {n_log + n_span} chegaram')

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'gen': gen(sys.argv[2], sys.argv[3])
    elif cmd == 'send': send(sys.argv[2], sys.argv[3])
    elif cmd == 'ready': sys.exit(ready(sys.argv[2], sys.argv[3]))
    elif cmd == 'check': check(sys.argv[2], sys.argv[3])
PY
python3 -I "$TMP/redact.py" gen "$TMP/casos.json" "$RUN" || die "gerar os casos"
python3 -I "$TMP/redact.py" send "$SCHEME://127.0.0.1:$HTTP" "$TMP/casos.json" || die "mandar os casos ao collector"
for _ in $(seq 1 120); do python3 -I "$TMP/redact.py" ready "$TMP/casos.json" "$S3D/objects.jsonl" 2>/dev/null && break; sleep 0.5; done
python3 -I "$TMP/redact.py" check "$TMP/casos.json" "$S3D/objects.jsonl" > "$TMP/res.txt" 2>&1
check_py_lines "$TMP/res.txt"
check "o S3 falso recebeu o lote (objetos gravados)" [ -s "$S3D/objects.jsonl" ]

# ---------------------------------------------------------------- conteúdo de ferramenta desligado por padrão
check "compose: OTEL_LOG_TOOL_CONTENT desligado por padrão e sobrescrevível" \
  grep -qxF '      OTEL_LOG_TOOL_CONTENT: ${OTEL_LOG_TOOL_CONTENT:-0}' "$ROOT/docker/compose.yaml"
# o oute-emit run não leva a chave do ~/.oute_env ao agente headless (TELEMETRY_KEYS)
H="$TMP/home-emit"; mkdir -p "$H"
printf 'declare -x OTEL_LOG_TOOL_CONTENT="1"\n' > "$H/.oute_env"
check "oute-emit run: a chave do ~/.oute_env não chega ao agente headless" \
  env -i HOME="$H" PATH="$PATH" "$ROOT/docker/oute-emit" run -- sh -c '[ -z "${OTEL_LOG_TOOL_CONTENT:-}" ]'

check_end
