// Botões Copiar (#468): copiam o texto do elemento que o botão aponta (`aria-controls`) e só isso. Sem o script os botões
// seguem escondidos (nascem com `hidden`) e o texto fica à vista para selecionar. Sem a API da área de transferência
// (página fora de contexto seguro) o texto é só selecionado, para o Ctrl+C.
(function () {
  function selecionar(alvo) {
    var faixa = document.createRange();
    faixa.selectNodeContents(alvo);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(faixa);
  }
  document.querySelectorAll("button.copiar[aria-controls]").forEach(function (btn) {
    var alvo = document.getElementById(btn.getAttribute("aria-controls"));
    var rotulo = btn.querySelector("span");
    if (!alvo || !rotulo) return;
    var original = rotulo.textContent;
    var aviso = document.createElement("span");
    aviso.className = "so-leitor";
    aviso.setAttribute("role", "status");
    btn.after(aviso);
    btn.hidden = false;
    function dizer(texto, copiado) {
      rotulo.textContent = texto;
      btn.classList.toggle("copiado", copiado);
      aviso.textContent = texto;
      window.setTimeout(function () {
        rotulo.textContent = original;
        btn.classList.remove("copiado");
        aviso.textContent = "";
      }, 2000);
    }
    btn.addEventListener("click", function () {
      if (!navigator.clipboard || !window.isSecureContext) {
        selecionar(alvo);
        dizer("Selecionado: Ctrl+C", false);
        return;
      }
      navigator.clipboard.writeText(alvo.textContent).then(function () {
        dizer("Copiado", true);
      }, function () {
        selecionar(alvo);
        dizer("Não copiou: Ctrl+C", false);
      });
    });
  });
})();
