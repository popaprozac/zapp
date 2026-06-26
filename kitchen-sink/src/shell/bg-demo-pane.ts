/** Standalone pane for the backgroundExtension demo windows.
 *
 * Opened via Window.create({ url: "#bg-demo=mirror" }) or "#bg-demo=extend"
 * from the Multi-window section. The full-bleed gradient IS the demo content —
 * the effect is only visible when there is rich colour behind the glass chrome.
 */

import { Events, Window } from "@zappdev/runtime";

const VARIANTS: Record<string, string> = {
  aurora: "linear-gradient(135deg,#aa3bff,#3b82f6,#06b6d4)",
  mesh: "radial-gradient(at 20% 20%,#f472b6,transparent 50%),radial-gradient(at 80% 30%,#facc15,transparent 50%),radial-gradient(at 50% 80%,#22d3ee,transparent 50%),#1e1e2e",
};

function applyVariant(v: string) {
  document.body.style.cssText =
    `margin:0; min-height:100vh; background:${VARIANTS[v] ?? VARIANTS.aurora}`;
}

export function renderBgDemoPane(app: HTMLElement) {
  // Parse mode from hash: "#bg-demo=mirror" → "mirror", default "mirror".
  const raw = location.hash.split("=")[1] ?? "mirror";
  const mode = raw === "extend" ? "extend" : "mirror";

  // Full-bleed vivid gradient — the demo "media" that makes the glass effect visible.
  applyVariant("aurora");

  const desc =
    mode === "mirror"
      ? "The sidebar glass <em>mirrors</em> this content — the gradient reflects behind the chrome panel. Drag the divider; reflow defers to drag-settle."
      : "Content <em>extends</em> under the sidebar glass — the gradient flows edge-to-edge beneath the chrome. The card below clears the sidebar via <code>--zapp-safe-area-left</code>.";

  app.innerHTML = `
    <div style="
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; box-sizing: border-box;
      padding-left: var(--zapp-safe-area-left, 0px);
    ">
      <div style="
        background: rgba(255,255,255,0.18);
        backdrop-filter: blur(20px) saturate(1.6);
        -webkit-backdrop-filter: blur(20px) saturate(1.6);
        border: 1px solid rgba(255,255,255,0.35);
        border-radius: 16px;
        padding: 32px 36px;
        max-width: 380px;
        box-shadow: 0 8px 32px rgba(0,0,0,0.18);
        color: #fff;
        text-align: center;
      ">
        <div style="
          font-size: 11px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
          opacity: 0.7; margin-bottom: 10px;
        ">backgroundExtension</div>
        <div style="
          font-size: 26px; font-weight: 700; margin-bottom: 16px; letter-spacing: -0.01em;
        ">${mode}</div>
        <div style="
          font-size: 13px; line-height: 1.6; opacity: 0.88;
        ">${desc}</div>
        <div style="
          margin-top: 22px; font-size: 11px; opacity: 0.5; font-family: monospace;
        ">Drag the sidebar divider to see the effect.</div>
      </div>
    </div>`;

  // Listen for the small sidebar's nav events (windowId-scoped).
  Events.on("ks:bg-nav", ({ variant, windowId }: any) => {
    if (windowId === Window.current().id) applyVariant(variant);
  });
}

/** Minimal 2-item sidebar for the bg-extension demo windows. */
export function renderBgSidebarPane(app: HTMLElement) {
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">BACKGROUND</div>
      <nav>
        <button class="nav-item active" data-v="aurora">Aurora</button>
        <button class="nav-item" data-v="mesh">Mesh</button>
      </nav>
    </div>`;
  const items = app.querySelectorAll<HTMLButtonElement>(".nav-item");
  items.forEach((el) => el.addEventListener("click", () => {
    items.forEach((i) => i.classList.toggle("active", i === el));
    Events.emit("ks:bg-nav", { variant: el.dataset.v!, windowId: Window.current().id });
  }));
}
