/** Build a section "card": a titled block with a button row and a result area.
 *  Returns the card element; query buttons by their data-act value. */
export function card(opts: {
  title: string;
  intro?: string;
  buttons: { act: string; label: string }[];
  /** Optional platform/behavior note rendered under the buttons (allows inline HTML). */
  note?: string;
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
    ${opts.note ? `<p class="note">${opts.note}</p>` : ""}
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

const escHtml = (s: unknown) =>
  String(s).replace(/[<&>"]/g, (c) => ({ "<": "&lt;", "&": "&amp;", ">": "&gt;", '"': "&quot;" }[c]!));

/** Build a live inspector panel: a titled block of key/value fields plus an
 *  optional scrolling event log. Returns `set(key, value)` to update a field
 *  and `log(label, detail?, hit?)` to prepend a timestamped row (hit=true
 *  highlights a user interaction). Section inspector()s pair this with an
 *  Events subscription (render + inspector run in different webview panes). */
export function inspectorPanel(
  host: HTMLElement,
  opts: {
    title: string;
    fields?: { key: string; label: string; init?: string }[];
    log?: { title: string; empty: string };
  },
): { set(key: string, value: string): void; log(label: string, detail?: string, hit?: boolean): void } {
  const fields = opts.fields ?? [];
  const fieldsHtml = fields
    .map((f) => `<div class="muted" data-f="${f.key}">${escHtml(f.label)}: ${escHtml(f.init ?? "—")}</div>`)
    .join("");
  const logHtml = opts.log
    ? `<div class="kv" style="margin-top:14px"><b>${escHtml(opts.log.title)}</b>` +
      `<div class="insp-log" data-log><p class="muted" data-empty>${escHtml(opts.log.empty)}</p></div></div>`
    : "";
  host.innerHTML = `<div class="kv"><b>${escHtml(opts.title)}</b>${fieldsHtml}</div>${logHtml}`;
  const logEl = host.querySelector<HTMLElement>("[data-log]");
  const labels = new Map(fields.map((f) => [f.key, f.label]));
  return {
    set(key, value) {
      const el = host.querySelector<HTMLElement>(`[data-f="${key}"]`);
      if (el) el.textContent = `${labels.get(key) ?? key}: ${value}`;
    },
    log(label, detail = "", hit = false) {
      if (!logEl) return;
      logEl.querySelector("[data-empty]")?.remove();
      const row = document.createElement("div");
      row.className = "insp-row" + (hit ? " insp-row--hit" : "");
      const t = new Date().toLocaleTimeString();
      row.innerHTML =
        `<span class="insp-t">${t}</span> <b>${escHtml(label)}</b>` +
        (detail ? ` <span class="muted">${escHtml(detail)}</span>` : "");
      logEl.insertBefore(row, logEl.firstChild);
      while (logEl.childElementCount > 40) logEl.lastElementChild!.remove();
    },
  };
}
