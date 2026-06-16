import "./style.css";

const hash = location.hash;
const app = document.querySelector<HTMLDivElement>("#app")!;
const label =
  hash === "#sidebar-pane" ? "SIDEBAR PANE" :
  hash === "#inspector-pane" ? "INSPECTOR PANE" :
  "MAIN PANE";
app.innerHTML = `<div style="padding:var(--zapp-titlebar-height,52px) 16px 16px;font:13px system-ui">${label}</div>`;
document.body.style.background = (hash === "#sidebar-pane" || hash === "#inspector-pane") ? "transparent" : "";
