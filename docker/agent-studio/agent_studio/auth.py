"""Autenticação do agent-studio (ADR-08 §6): duas credenciais do vault (#256) e, para marcar ação na tela, uma terceira (#510).

- **Ingestão** (`POST /v1/logs|traces|metrics`): só o collector tem; pasta `oute-services` do vault, nunca vai ao
  container `agent`. `Authorization: Bearer <credencial de ingestão>`.
- **Leitura** (`GET /v1/usage|alerts|tray` e a tela): agente, tray e navegador; pasta `oute-agent`. Com ela, a
  ingestão responde 403. A de ingestão não lê.
- **Marcação** (`POST /rodada/acao`, #510): a **credencial de marcação**, terceira, que só o navegador do Bardi tem; pasta
  `oute-services` do vault, nunca vai ao container `agent` (o agente tem a de leitura e alcança o studio pela rede docker: se a
  rota aceitasse a leitura, aceitaria o agente). Cookie próprio (`agent_studio_mark`), `HttpOnly`, `Secure`, `SameSite=Strict`,
  que leva um HMAC dela, como o de leitura. Mais um campo oculto com outro HMAC (`csrf`), que só a página para quem tem o cookie
  de marcação mostra. Sem a credencial configurada (`mark` falso), a rota e a tela de entrada não existem. Ela precisa ser
  diferente da de ingestão e da de leitura: igual a uma delas, o `__main__` a descarta.
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
MARK_COOKIE = "agent_studio_mark"
# o cookie de marcação só vai às páginas da rodada e à rota de marcar (`/rodada`, `/rodada/acao`); Strict: nem em navegação vinda de outro site
MARK_COOKIE_FLAGS = {"path": "/rodada", "secure": True, "httponly": True, "samesite": "strict"}


class Auth:
    def __init__(self, ingest_token, read_token=None, mark_token=None):
        if not ingest_token:
            raise ValueError("token vazio")
        read_token = read_token or ingest_token
        if mark_token and mark_token in (ingest_token, read_token):
            raise ValueError("a credencial de marcação precisa ser diferente das outras duas")
        # duas credenciais de verdade? (falso = transição: uma só para ingestão e leitura)
        self.split = read_token != ingest_token
        self._ingest_bearer = f"Bearer {ingest_token}".encode()
        self._token = read_token.encode()
        self._bearer = f"Bearer {read_token}".encode()
        self.cookie_value = hmac.new(self._token, b"agent-studio cookie v1", hashlib.sha256).hexdigest()
        # credencial de marcação (#510): sem ela, `mark` é falso e a rota não existe
        self.mark = bool(mark_token)
        self._mark_token = (mark_token or "").encode()
        self.mark_cookie_value = hmac.new(self._mark_token, b"agent-studio mark cookie v1", hashlib.sha256).hexdigest() if self.mark else ""
        self.mark_csrf = hmac.new(self._mark_token, b"agent-studio mark csrf v1", hashlib.sha256).hexdigest() if self.mark else ""

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

    # ------------------------------------------------ marcação (#510)
    def mark_token_ok(self, got):
        """A credencial colada na tela de marcar confere? Sem credencial configurada, nunca."""
        return self.mark and hmac.compare_digest((got or "").encode(), self._mark_token)

    def marker(self, request):
        """O pedido traz o cookie de marcação? (a credencial de leitura, em cookie ou `Bearer`, não vale aqui)"""
        return self.mark and hmac.compare_digest(request.cookies.get(MARK_COOKIE, "").encode(), self.mark_cookie_value.encode())

    def csrf_ok(self, got):
        """O campo oculto do formulário é o HMAC da credencial de marcação?"""
        return self.mark and hmac.compare_digest((got or "").encode(), self.mark_csrf.encode())

    def set_mark_cookie(self, response):
        response.set_cookie(MARK_COOKIE, self.mark_cookie_value, max_age=COOKIE_MAX_AGE, **MARK_COOKIE_FLAGS)
