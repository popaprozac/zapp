import { Events } from "@zappdev/runtime";

export function renderPopoverPane(app: HTMLElement) {
  document.body.style.background = "transparent";
  let n = 0;
  app.innerHTML = `
    <div style="padding:14px;font:13px system-ui">
      <div style="font-weight:600;margin-bottom:8px">Web content in an NSPopover</div>
      <button data-count>Count: 0</button>
      <button data-emit>Emit → main pane</button>
      <div class="muted" style="margin-top:10px;font-size:11px">Same popover instance — re-anchored to the button or the Compose toolbar item.</div>
    </div>`;
  app.querySelector("[data-count]")!.addEventListener("click", (e) => {
    (e.currentTarget as HTMLElement).textContent = `Count: ${++n}`; // survives hide/show
  });
  app.querySelector("[data-emit]")!.addEventListener("click", () => {
    Events.emit("ks:popover-emit", { from: "popover" });
  });
}
