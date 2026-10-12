# Roda um comando com o stdin ligado a um socket, como o shell que uma ferramenta abre (o Bash tool do Claude Code):
# o bash lê o ~/.bashrc nesse caso mesmo sem ser interativo (o modo rshd). O stdout e o código de saída são os do
# comando. Uso: python3 -I tests/lib/sock-stdin.py <comando…>
import socket, subprocess, sys

a, _ = socket.socketpair()
sys.exit(subprocess.run(sys.argv[1:], stdin=a).returncode)
