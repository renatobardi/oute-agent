/* #536: falha de um bloco troca só seu espaço; 401 segue o HX-Redirect do servidor. */
document.addEventListener("htmx:beforeSwap", function (event) {
  if (event.detail.target.matches("[data-bloco], [data-bloco-erro], [data-inline-bloco]") &&
      event.detail.xhr.status >= 400 && event.detail.xhr.status !== 401) {
    event.detail.shouldSwap = true;
    event.detail.isError = false;
  }
});
function blockNetworkError(event) {
  const selector = "[data-bloco], [data-bloco-erro], [data-inline-bloco]";
  const block = event.detail.target?.closest(selector) || event.detail.elt.closest(selector);
  if (!block) return;
  block.setAttribute("aria-busy", "false");
  const url = block.getAttribute("hx-get") || block.dataset.retryUrl || event.detail.elt.getAttribute("hx-get");
  block.dataset.retryUrl = url;
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
  const holder = block.matches?.("tr") ? document.createElement("td") : block;
  if (holder !== block) { holder.setAttribute("colspan", "4"); block.replaceChildren(holder); }
  if (fallback) holder.replaceChildren(message, retry, fallback);
  else holder.replaceChildren(message, retry);
}
document.addEventListener("htmx:sendError", blockNetworkError);
document.addEventListener("htmx:timeout", blockNetworkError);

document.addEventListener("htmx:beforeRequest", function (event) {
  const target = event.detail.target;
  if (!target.matches("[data-inline-bloco]")) return;
  target.setAttribute("aria-busy", "true");
  const url = event.detail.elt.getAttribute("hx-get") || target.dataset.retryUrl;
  target.dataset.retryUrl = url;
  const slot = document.createElement("div");
  slot.className = "carregamento " + target.dataset.inlineBloco;
  const shimmer = document.createElement("div");
  shimmer.className = "shimmer";
  shimmer.setAttribute("aria-hidden", "true");
  for (let i = 0; i < 4; i++) shimmer.appendChild(document.createElement("span"));
  const link = document.createElement("a");
  link.dataset.full = "";
  link.setAttribute("href", url + "&full=1");
  link.textContent = "Ver a página inteira";
  slot.append(shimmer, link);
  const parent = target.matches("tr") ? target.querySelector("td") : target;
  parent.appendChild(slot);
});

document.addEventListener("htmx:afterSwap", function (event) {
  if (event.detail?.target?.matches("[data-inline-bloco]")) event.detail.target.setAttribute("aria-busy", "false");
  document.querySelectorAll("template[data-document-title]").forEach(function (title) {
    document.title = title.content.textContent;
    title.remove();
  });
});
