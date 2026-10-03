"""Autenticação do agent-studio (ADR-08 §6): duas credenciais do vault (#256).

- **Ingestão** (`POST /v1/logs|traces|metrics`): só o collector tem; pasta `oute-services` do vault, nunca vai ao
  container `agent`. `Authorization: Bearer <credencial de ingestão>`.
- **Leitura** (`GET /v1/usage|alerts|tray` e a tela): agente, tray e navegador; pasta `oute-agent`. Com ela, a
  ingestão responde 403. A de ingestão não lê.
- Transição: sem a credencial de leitura (ou com as duas iguais), vale uma só para tudo, como antes da #256
  (`split` falso; o `__main__` avisa no stderr).
- Navegador (#206): cola a credencial de leitura uma vez no `/login` e recebe um cookie. O cookie **não leva a
  credencial**: leva um HMAC dela, que só quem a tem calcula. Sem estado no servidor: trocar a credencial no vault
  (e `oute up`) invalida todo cookie emitido.
"""
import hashlib
import hmac

COOKIE = "agent_studio"
COOKIE_MAX_AGE = 90 * 86400  # "cola o token uma vez": 90 dias
# HttpOnly (script nenhum lê), Secure (só HTTPS; o navegador aceita em localhost) e SameSite=Lax (não vai em
# POST nem em sub-recurso de outro site; link de fora para a tela continua abrindo logado)
COOKIE_FLAGS = {"path": "/", "secure": True, "httponly": True, "samesite": "lax"}


class Auth:
    def __init__(self, ingest_token, read_token=None):
        if not ingest_token:
            raise ValueError("token vazio")
        read_token = read_token or ingest_token
        # duas credenciais de verdade? (falso = transição: uma só para ingestão e leitura)
        self.split = read_token != ingest_token
        self._ingest_bearer = f"Bearer {ingest_token}".encode()
        self._token = read_token.encode()
        self._bearer = f"Bearer {read_token}".encode()
        self.cookie_value = hmac.new(self._token, b"agent-studio cookie v1", hashlib.sha256).hexdigest()

    def token(self, got):
        """A credencial colada no login confere? (a de leitura)"""
        return hmac.compare_digest((got or "").encode(), self._token)

    def ingest(self, request):
        """Ingestão (POST): só o `Bearer` da credencial de ingestão."""
        return hmac.compare_digest(request.headers.get("authorization", "").encode(), self._ingest_bearer)

    def bearer(self, request):
        """`Bearer` da credencial de leitura."""
        return hmac.compare_digest(request.headers.get("authorization", "").encode(), self._bearer)

    def cookie(self, request):
        return hmac.compare_digest(request.cookies.get(COOKIE, "").encode(), self.cookie_value.encode())

    def reader(self, request):
        """Leitura (páginas e GET da API): `Bearer` da credencial de leitura ou o cookie do login."""
        return self.bearer(request) or self.cookie(request)

    def set_cookie(self, response):
        response.set_cookie(COOKIE, self.cookie_value, max_age=COOKIE_MAX_AGE, **COOKIE_FLAGS)

    def clear_cookie(self, response):
        response.delete_cookie(COOKIE, **COOKIE_FLAGS)
