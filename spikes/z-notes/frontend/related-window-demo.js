import { createRelatedWindow, RelatedWindowEvent } from "@zappdev/runtime/window";

// One owner, ordinary object/function identity, separate native documents.
// The demo styles its small child explicitly; CSS synchronization is separate.
export function installRelatedWindowDemo() {
  const open = document.querySelector("#related-inspector");
  const closeAll = document.querySelector("#close-inspectors");
  const status = document.querySelector("#related-status");
  const title = document.querySelector("#note-title");
  const createNote = document.querySelector("#ping");
  const inspectors = new Set();
  const state = { edits: 0 };
  const renders = new Set();
  const render = () => {
    status.textContent = `${inspectors.size} related inspector(s); ${state.edits} shared title edits. No second frontend was loaded.`;
    for (const update of renders) update();
  };
  title.addEventListener("input", () => { state.edits++; render(); });
  open.addEventListener("click", async () => {
    open.disabled = true;
    try {
      const inspector = await createRelatedWindow({ title: "Note inspector", width: 440, height: 300 });
      const child = inspector.document;
      const panel = child.createElement("main");
      panel.style.cssText = "font:15px system-ui;padding:24px;color:#20242b;background:#f6f8fc;min-height:100vh;box-sizing:border-box";
      child.body.style.margin = "0";
      const heading = child.createElement("h1"); heading.textContent = "Shared note title";
      const explanation = child.createElement("p");
      explanation.textContent = "Edit here or in Z Notes. Both documents use the same frontend owner and callbacks.";
      const input = child.createElement("input"); input.setAttribute("aria-label", "Shared note title");
      input.style.cssText = "display:block;box-sizing:border-box;width:100%;padding:8px;margin-bottom:12px";
      const save = child.createElement("button"); save.textContent = "Create note using owner service";
      // This is owner code even though its button lives in the child document.
      // Native calls from child-local code would use that child's own bridge.
      save.onclick = () => createNote.click();
      const close = child.createElement("button"); close.textContent = "Close inspector";
      close.style.marginLeft = "8px"; close.onclick = () => inspector.close();
      const edits = child.createElement("p");
      const update = () => { input.value = title.value; edits.textContent = `Shared edits: ${state.edits}`; };
      input.oninput = () => { title.value = input.value; title.dispatchEvent(new Event("input")); };
      panel.append(heading, explanation, input, save, close, edits);
      child.body.append(panel);
      inspectors.add(inspector); renders.add(update);
      inspector.subscribe(RelatedWindowEvent.INVALIDATED, () => {
        inspectors.delete(inspector); renders.delete(update);
        input.oninput = null; save.onclick = null; close.onclick = null;
        panel.remove(); render();
      });
      render();
    } catch (error) {
      status.textContent = `${error.code ?? "ERROR"}: ${error.message}`;
    } finally { open.disabled = false; }
  });
  closeAll.addEventListener("click", () => { for (const inspector of inspectors) inspector.close(); });
}
