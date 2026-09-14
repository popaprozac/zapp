// Real WebKit CSS inheritance/composed-path proof. This only classifies DOM
// events; it does not synthesize native mouse input or claim native dragging.
import { resolveWindowDrag, windowDragPath } from "../../../../bootstrap/window-drag";

export function verifyWindowDragPolicy(doc: Document): void {
  const root = doc.createElement("section");
  root.style.cssText = "position:fixed;left:-10000px;top:0";
  root.innerHTML = `<header data-zapp-titlebar style="--zapp-drag:drag">
    <span class="text">Notes</span><button><svg><path/></svg></button>
    <input><a href="#">Link</a><div contenteditable="true"><span class="edit">Edit</span></div>
    <div class="excluded" style="--zapp-drag:no-drag"><span data-zapp-drag-region>Excluded</span></div>
    <div class="handle" data-zapp-drag-region>Move only</div><div class="host"></div>
  </header>`;
  doc.body.append(root);
  let observed = "none";
  const checkPath = (event: Event) => { observed = resolveWindowDrag(windowDragPath(event)); };
  doc.addEventListener("zapp-drag-policy-probe", checkPath, true);
  const check = (target: Element, expected: string) => {
    observed = "unobserved";
    target.dispatchEvent(new doc.defaultView!.Event("zapp-drag-policy-probe", { bubbles: true, composed: true }));
    if (observed !== expected) throw new Error(`Drag policy: ${target.localName} expected ${expected}, found ${observed}`);
  };
  try {
    check(root.querySelector(".text")!, "titlebar");
    for (const selector of ["path", "input", "a", ".edit", ".excluded span"]) check(root.querySelector(selector)!, "none");
    check(root.querySelector(".handle")!, "move");
    const shadow = root.querySelector(".host")!.attachShadow({ mode: "open" });
    shadow.innerHTML = '<button><span>Shadow button</span></button><span class="plain">Shadow label</span>';
    check(shadow.querySelector("button span")!, "none");
    check(shadow.querySelector(".plain")!, "titlebar");
    const header = root.querySelector("header")!;
    header.style.setProperty("--zapp-drag", "no-drag");
    check(root.querySelector(".handle")!, "none");
    header.style.setProperty("--zapp-drag", "drag");
    check(root.querySelector(".text")!, "titlebar");
    // Reparenting is observed immediately; no hover flag decides the result.
    const text = root.querySelector(".text")!;
    root.querySelector("button")!.append(text);
    check(text, "none");
  } finally {
    doc.removeEventListener("zapp-drag-policy-probe", checkPath, true);
    root.remove();
  }
}
