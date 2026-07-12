/**
 * Transparent-window demo content. Opened via Window.create({ transparent: true })
 * or ({ windows: { backdrop: "mica" } }). The surface is made see-through so the
 * window's transparency (WS_EX_NOREDIRECTIONBITMAP + alpha-0 webview) reveals the
 * desktop / DWM backdrop behind; an opaque card proves content still renders.
 */
export function renderTransparentDemo(app: HTMLElement) {
  // Override the shell's opaque background so the window transparency shows.
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  app.style.background = "transparent";
  app.innerHTML = `
    <div data-zapp-titlebar
         style="height:100vh;display:flex;align-items:center;justify-content:center;
                background:transparent;font-family:system-ui,sans-serif;">
      <div style="background:rgba(28,28,30,0.82);color:#fff;padding:28px 36px;border-radius:16px;
                  box-shadow:0 16px 56px rgba(0,0,0,0.45);text-align:center;max-width:340px;
                  border:1px solid rgba(255,255,255,0.08);">
        <div style="font-size:34px;line-height:1;margin-bottom:10px;">🪟</div>
        <h2 style="margin:0 0 8px;font-size:19px;">Transparent window</h2>
        <p style="margin:0;opacity:0.72;font-size:13px;line-height:1.5;">
          The area around this card is see-through — you should see your desktop
          (or the Mica/Acrylic backdrop) behind it. This card is opaque content on
          a transparent WebView2 surface. Drag anywhere to move.
        </p>
      </div>
    </div>`;
}
