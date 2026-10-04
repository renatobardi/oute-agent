# Receptor OTLP falso e oute-emit no PATH dos temas que conferem eventos (#124). Para `source` depois do swarm.sh.
# cada linha do log da rodada também chega ao receptor como log OTLP (oute-emit), com a origem e o oute.agent
. "$ROOT/tests/lib/otlp.sh"
trap 'rcv_stop; rm -rf "$TMP"' EXIT
ln -sf "$ROOT/docker/oute-emit" "$BIN/oute-emit"
export OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent"

