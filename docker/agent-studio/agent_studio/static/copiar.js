// Botões Copiar (#468): copiam o texto do elemento que o botão aponta (`aria-controls`) e só isso. Sem o script os botões
// seguem escondidos (nascem com `hidden`) e o texto fica à vista para selecionar.
(function () {
  function copiar(texto, alvo) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(texto);
    return new Promise(function (ok, falha) {
      var faixa = document.createRange();
      faixa.selectNodeContents(alvo);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(faixa);
      var feito = false;
      try { feito = document.execCommand("copy"); } catch (e) { feito = false; }
      sel.removeAllRanges();
      if (feito) ok(); else falha(new Error("copiar"));
    });
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
    btn.addEventListener("click", function () {
      copiar(alvo.textContent, alvo).then(function () {
        rotulo.textContent = "Copiado";
        btn.classList.add("copiado");
        aviso.textContent = "Copiado";
      }, function () {
        rotulo.textContent = "Não copiou";
        aviso.textContent = "Não foi possível copiar";
      }).then(function () {
        window.setTimeout(function () {
          rotulo.textContent = original;
          btn.classList.remove("copiado");
          aviso.textContent = "";
        }, 2000);
      });
    });
  });
})();
