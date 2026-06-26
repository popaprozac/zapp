/** The color-demo window's two panes: a descriptive (no-nav) sidebar and a
 *  focused content page explaining the backgroundColor API. */
export function renderColorSidebarPane(app: HTMLElement) {
  document.documentElement.style.background = "transparent";
  document.body.style.background = "transparent";
  app.innerHTML = `
    <div class="sidebar-pane">
      <div class="sidebar-title">COLOR</div>
      <div style="padding:8px 4px; font:13px system-ui; line-height:1.6; opacity:0.92;">
        This sidebar's <code>backgroundColor</code> is a translucent
        <b>rgba(170,59,255,0.4)</b> — the window's opaque <b>teal</b> shows
        through it. No nav items here; it's a pure color demo.
      </div>
    </div>`;
}

export function renderColorContentPane(app: HTMLElement) {
  app.innerHTML = `
    <div style="padding:28px; font:14px system-ui; line-height:1.7; max-width:520px;">
      <h2 style="margin:0 0 12px;">Window background color</h2>
      <p>This window's <code>backgroundColor</code> is the CSS name <b>"teal"</b> (opaque).
         The translucent sidebar lets it show through.</p>
      <p><code>backgroundColor</code> accepts:</p>
      <ul style="line-height:1.9;">
        <li>CSS names — <code>teal</code>, <code>rebeccapurple</code></li>
        <li>hex — <code>#1e1e1e</code>, <code>#aa3bffcc</code></li>
        <li><code>rgb(0, 128, 128)</code> / <code>rgba(170, 59, 255, 0.4)</code></li>
      </ul>
      <p style="opacity:0.6;">Resize the window — the color fills any pre-render / resize gap.</p>
    </div>`;
}
