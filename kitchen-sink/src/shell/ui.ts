/** Build a section "card": a titled block with a button row and a result area.
 *  Returns the card element; query buttons by their data-act value. */
export function card(opts: {
  title: string;
  intro?: string;
  buttons: { act: string; label: string }[];
}): HTMLElement {
  const el = document.createElement("section");
  el.className = "card";
  const btns = opts.buttons
    .map((b) => `<button data-act="${b.act}">${b.label}</button>`)
    .join("");
  el.innerHTML = `
    <h2>${opts.title}</h2>
    ${opts.intro ? `<p class="intro">${opts.intro}</p>` : ""}
    <div class="row">${btns}</div>
    <div class="result" data-result></div>`;
  return el;
}

/** Wire a click handler keyed by data-act. */
export function onAct(host: HTMLElement, act: string, fn: () => void) {
  host.querySelector<HTMLButtonElement>(`[data-act="${act}"]`)
    ?.addEventListener("click", fn);
}

/** Write to the card's result area. */
export function setResult(host: HTMLElement, msg: string) {
  const r = host.querySelector<HTMLDivElement>("[data-result]");
  if (r) r.textContent = msg;
}
