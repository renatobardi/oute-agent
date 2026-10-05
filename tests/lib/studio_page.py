"""curl dos testes da tela: pede o casco e os trechos, preservando flags e autenticação."""
import subprocess
import sys
from urllib.parse import urlsplit

from studio_loading import expand

args = sys.argv[1:]
result = subprocess.run(['curl', '-s', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
if result.returncode or any(a in args for a in ('-o', '-D', '-I', '--head', '-X', '--data-binary')):
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
url_index = next((i for i, a in enumerate(args) if '://' in a), None)
if url_index is None:
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)
url = urlsplit(args[url_index])
origin = url.scheme + '://' + url.netloc


def fetch(path, query):
    sent = args.copy()
    sent[url_index] = origin + path + '?' + query
    # Os testes que conferem status usam curl diretamente; este apoio monta só o HTML.
    r = subprocess.run(['curl', '-s', *sent], capture_output=True, check=True)
    return 200, r.stdout.decode()


_, html = expand(result.stdout.decode(), fetch)
sys.stdout.write(html)
