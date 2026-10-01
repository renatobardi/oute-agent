"""Autenticação do agent-studio (ADR-08 §6): um token só, do vault.

- API: `Authorization: Bearer <token>`.
- Navegador (#206): cola o token uma vez no `/login` e recebe um cookie. O cookie **não leva o token**: leva um
  HMAC dele, que só quem tem o token calcula. Sem estado no servidor: trocar o token no vault (e `oute up`)
  invalida todo cookie emitido.
"""
import hashlib
import hmac

COOKIE = "agent_studio"
COOKIE_MAX_AGE = 90 * 86400  # "cola o token uma vez": 90 dias
# HttpOnly (script nenhum lê), Secure (só HTTPS; o navegador aceita em localhost) e SameSite=Lax (não vai em
# POST nem em sub-recurso de outro site; link de fora para a tela continua abrindo logado)
COOKIE_FLAGS = {"path": "/", "secure": True, "httponly": True, "samesite": "lax"}


class Auth:
    def __init__(self, token):
        if not token:
            raise ValueError("token vazio")
        self._token = token.encode()
        self._bearer = f"Bearer {token}".encode()
        self.cookie_value = hmac.new(self._token, b"agent-studio cookie v1", hashlib.sha256).hexdigest()

    def token(self, got):
        """O token colado no login confere?"""
        return hmac.compare_digest((got or "").encode(), self._token)

    def bearer(self, request):
        return hmac.compare_digest(request.headers.get("authorization", "").encode(), self._bearer)

    def cookie(self, request):
        return hmac.compare_digest(request.cookies.get(COOKIE, "").encode(), self.cookie_value.encode())

    def reader(self, request):
        """Leitura (páginas e GET da API): `Bearer` ou cookie. A ingestão (POST) segue só com `Bearer`."""
        return self.bearer(request) or self.cookie(request)

    def set_cookie(self, response):
        response.set_cookie(COOKIE, self.cookie_value, max_age=COOKIE_MAX_AGE, **COOKIE_FLAGS)

    def clear_cookie(self, response):
        response.delete_cookie(COOKIE, **COOKIE_FLAGS)
