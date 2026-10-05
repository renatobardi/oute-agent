/* #536: falha de um bloco troca só seu espaço; 401 segue o HX-Redirect do servidor. */
document.addEventListener("htmx:beforeSwap", function (event) {
  if (event.detail.target.matches("[data-bloco], [data-bloco-erro]") &&
      event.detail.xhr.status >= 400 && event.detail.xhr.status !== 401) {
    event.detail.shouldSwap = true;
    event.detail.isError = false;
  }
});
function blockNetworkError(event) {
  const block = event.detail.elt.closest("[data-bloco], [data-bloco-erro]");
  if (!block) return;
  block.setAttribute("aria-busy", "false");
  const url = block.getAttribute("hx-get") || block.getAttribute("data-retry-url") || event.detail.elt.getAttribute("hx-get");
  block.setAttribute("data-retry-url", url);
  const fallback = block.querySelector("a[data-full]");
  const message = document.createElement("p");
  message.setAttribute("role", "alert");
  message.textContent = "O bloco não chegou. Confira a conexão e tente novamente.";
  const retry = document.createElement("button");
  retry.className = "botao";
  retry.textContent = "Tentar novamente";
  retry.addEventListener("click", function () {
    htmx.ajax("GET", url, {source: block, target: block, swap: "outerHTML"});
  });
  if (fallback) block.replaceChildren(message, retry, fallback);
  else block.replaceChildren(message, retry);
}
document.addEventListener("htmx:sendError", blockNetworkError);
document.addEventListener("htmx:timeout", blockNetworkError);

document.addEventListener("htmx:afterSwap", function () {
  document.querySelectorAll("template[data-document-title]").forEach(function (title) {
    document.title = title.content.textContent;
    title.remove();
  });
});
