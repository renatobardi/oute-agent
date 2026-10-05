/* Exercita eventos reais de loading.js com um DOM mínimo, sem dependências. */
const listeners = new Map();
const requests = [];
let titles = [];
const document = {
  title: "",
  addEventListener: (name, fn) => listeners.set(name, fn),
  createElement: tag => ({tag, attrs: new Map(), children: [], dataset: {},
    setAttribute(name, value) { this.attrs.set(name, value); },
    getAttribute(name) { return this.attrs.get(name); },
    append(...children) { this.children.push(...children); },
    appendChild(child) { this.children.push(child); },
    replaceChildren(...children) { this.children = children; },
    addEventListener(name, fn) { this[name] = fn; },
  }),
  querySelectorAll: () => titles,
};
globalThis.document = document;
globalThis.htmx = {ajax: (...a) => requests.push(a)};
require("../../docker/agent-studio/agent_studio/static/loading.js");
let failed = 0;
function check(name, passed) {
  process.stdout.write((passed ? "ok   " : "FAIL ") + name + "\n");
  if (!passed) failed++;
}
function swap(status, matches) {
  const event = {detail: {target: {matches: () => matches}, xhr: {status}}};
  listeners.get("htmx:beforeSwap")(event);
  return event.detail;
}
check("JS: erro HTTP troca só o bloco", swap(500, true).shouldSwap === true && swap(400, true).isError === false);
check("JS: 401 preserva o HX-Redirect", swap(401, true).shouldSwap === undefined);
check("JS: erro fora de um bloco preserva o comportamento do htmx", swap(500, false).shouldSwap === undefined);
const attrs = new Map([["hx-get", "/bloco/conversas/tabela?hours=168"]]);
const link = {};
const block = {
  dataset: {},
  getAttribute: name => attrs.get(name),
  setAttribute: (name, value) => attrs.set(name, value),
  querySelector: selector => { block.fallbackSelector = selector; return link; },
  replaceChildren: (...children) => { block.children = children; },
  closest: () => block,
};
const event = {detail: {elt: block}};
listeners.get("htmx:sendError")(event);
check("JS: falha de rede mostra texto local, encerra o estado ocupado e mantém o link", attrs.get("aria-busy") === "false" && block.children[0].textContent.includes("não chegou") && block.children[2] === link && block.fallbackSelector === "a[data-full]");
block.children[1].click();
check("JS: retentativa usa o mesmo endereço, alvo e origem", requests[0][0] === "GET" && requests[0][1] === attrs.get("hx-get") && requests[0][2].target === block && requests[0][2].source === block);
attrs.delete("hx-get");
listeners.get("htmx:timeout")(event);
block.children[1].click();
check("JS: prazo esgotado e segunda retentativa preservam o endereço", requests[1][1] === requests[0][1]);
let removed = false;
titles = [{content: {textContent: "Pedido · texto <não executável>"}, remove: () => { removed = true; }}];
listeners.get("htmx:afterSwap")({});
check("JS: título recebido vira texto e a marca é removida", document.title === titles[0].content.textContent && removed);
listeners.get("htmx:sendError")({detail: {elt: {closest: () => null}}});
check("JS: falha de rede fora de bloco não altera a página", requests.length === 2);
const cell = document.createElement("td");
cell.matches = selector => selector === "[data-inline-bloco]";
cell.closest = () => cell;
cell.dataset.inlineBloco = "faixa";
const anchor = document.createElement("a");
anchor.setAttribute("hx-get", "/conversa/span?trace=t&span=s");
listeners.get("htmx:beforeRequest")({detail: {target: cell, elt: anchor}});
check("JS: clique em span mostra shimmer e estado ocupado", cell.attrs.get("aria-busy") === "true" && cell.children[0].children[0].children.length === 4);
check("JS: clique preserva endereço e cria link sem JavaScript", cell.dataset.retryUrl === anchor.getAttribute("hx-get") && cell.children[0].children[1].getAttribute("href").endsWith("&full=1"));
listeners.get("htmx:afterSwap")({detail: {target: cell}});
check("JS: resposta do span encerra estado ocupado", cell.attrs.get("aria-busy") === "false");
const row = document.createElement("tr");
row.matches = selector => selector === "tr" || selector === "[data-inline-bloco]";
row.closest = () => row;
row.dataset.inlineBloco = "tabela";
row.querySelector = selector => selector === "td" ? cell : link;
listeners.get("htmx:beforeRequest")({detail: {target: row, elt: anchor}});
check("JS: mais logs coloca shimmer dentro da célula", cell.children.length === 2 && row.children.length === 0);
listeners.get("htmx:sendError")({detail: {target: row, elt: anchor}});
check("JS: falha de mais logs preserva linha e célula", row.children[0].tag === "td" && row.children[0].attrs.get("colspan") === "4" && row.children[0].children[0].textContent.includes("não chegou"));
process.exitCode = failed ? 1 : 0;
