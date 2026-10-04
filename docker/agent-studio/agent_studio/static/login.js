// Mostrar ou esconder o token na tela Entrar (#467). Sem o script o botão fica escondido e o campo segue como senha.
(function () {
  var btn = document.getElementById("token-ver");
  var campo = document.getElementById("token");
  if (!btn || !campo) return;
  btn.hidden = false;
  btn.addEventListener("click", function () {
    var ver = campo.type === "password";
    campo.type = ver ? "text" : "password";
    btn.setAttribute("aria-label", ver ? btn.dataset.esconder : btn.dataset.mostrar);
    btn.querySelector('[data-estado="oculto"]').hidden = ver;
    btn.querySelector('[data-estado="visivel"]').hidden = !ver;
  });
})();
