# Receptor OTLP falso e oute-emit no PATH dos temas que conferem eventos (#124). Para `source` depois do swarm.sh; o trap que derruba o receptor fica no teste (tests/parallel-lib.test.sh confere).
# cada linha do log da rodada também chega ao receptor como log OTLP (oute-emit), com a origem e o oute.agent
. "$ROOT/tests/lib/otlp.sh"
ln -sf "$ROOT/docker/oute-emit" "$BIN/oute-emit"
export OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent"

