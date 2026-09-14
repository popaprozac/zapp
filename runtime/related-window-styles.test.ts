import { expect, test } from "bun:test";
import { styleDOM } from "./related-window-dom.test";
import { shareRelatedWindowStyles } from "./related-window-styles";
import { normalizeRelatedWindowTheme, shareRelatedWindowTheme } from "./related-window-theme";

function style(doc: Document, text: string) {
  const node = doc.createElement("style"); node.textContent = text; doc.head.append(node); return node;
}
const sheets = (doc: Document) => [...doc.head.querySelectorAll<HTMLStyleElement | HTMLLinkElement>("style,link")];

test("siblings share one observer and cached source ordering; local sheets survive disposal", () => {
  const dom = styleDOM(), owner = dom.document(), a = dom.document(), b = dom.document();
  const first = style(owner, "a{color:red}"), second = style(owner, "a{color:blue}");
  const local = style(a, "a{color:green}");
  const disposeA = shareRelatedWindowStyles(owner, a, () => true), disposeB = shareRelatedWindowStyles(owner, b, () => true);
  expect(dom.observers()).toBe(1);
  expect(sheets(a).map(node => node.textContent)).toEqual([first.textContent, second.textContent, local.textContent]);
  const original = sheets(a)[1];
  for (let i = 0; i < 50; i++) second.textContent = `a{--count:${i}}`;
  dom.flush(); expect(sheets(a)[1]).toBe(original); expect(sheets(b)[1].textContent).toBe("a{--count:49}");
  owner.head.insertBefore(second, first); dom.flush(); expect(sheets(a)[0]).toBe(original);
  first.remove(); dom.flush(); expect(sheets(a)).toHaveLength(2);
  disposeA(); disposeA(); expect(sheets(a)).toEqual([local]); expect(dom.observers()).toBe(1);
  second.textContent = "a{color:black}"; dom.flush(); expect(sheets(b)[0].textContent).toBe(second.textContent);
  disposeB(); expect(dom.observers()).toBe(0); expect(sheets(b)).toHaveLength(0);
  const reopen = shareRelatedWindowStyles(owner, b, () => true); expect(dom.observers()).toBe(1);
  reopen(); expect(dom.observers()).toBe(0);
});

test("link request changes replace just that link, while media edits and nonce values are preserved", () => {
  const dom = styleDOM(), owner = dom.document(), child = dom.document();
  const link = owner.createElement("link"); link.setAttribute("rel", "stylesheet"); link.setAttribute("href", "./app.css"); link.nonce = "hidden-nonce";
  owner.head.append(link);
  const dispose = shareRelatedWindowStyles(owner, child, () => true);
  const original = sheets(child)[0];
  expect(original.getAttribute("href")).toBe("https://example.test/app/app.css"); expect(original.nonce).toBe("hidden-nonce");
  expect(link.hasAttribute("nonce")).toBe(false);
  link.setAttribute("media", "print"); dom.flush(); expect(sheets(child)[0]).toBe(original);
  link.setAttribute("href", "other.css"); dom.flush(); expect(sheets(child)[0]).not.toBe(original); expect(original.isConnected).toBe(false);
  expect(sheets(child)[0].getAttribute("media")).toBe("print");
  link.nonce = ""; link.setAttribute("media", "screen"); dom.flush(); expect(sheets(child)[0].nonce).toBe("");
  dispose();
});

test("queued mutations cannot repopulate an invalidated child", () => {
  const dom = styleDOM(), owner = dom.document(), child = dom.document(); let active = true;
  const source = style(owner, "a{color:red}");
  const dispose = shareRelatedWindowStyles(owner, child, () => active);
  source.textContent = "a{color:blue}"; active = false; dom.flush();
  expect(sheets(child)).toHaveLength(0); expect(dom.observers()).toBe(0); dispose();
});

test("unsupported initial sheets fail closed; bad hot edits preserve a snapshot and recover", () => {
  const dom = styleDOM(), owner = dom.document(), child = dom.document();
  const source = style(owner, 'a{background:image("unsupported")}');
  expect(() => shareRelatedWindowStyles(owner, child, () => true)).toThrow(); expect(dom.observers()).toBe(0);
  source.textContent = "a{color:red}";
  const dispose = shareRelatedWindowStyles(owner, child, () => true);
  const originalError = console.error; let reports = 0; console.error = () => { reports++; };
  try {
    source.textContent = 'a{background:image("unsupported")}'; dom.flush(); dom.flush();
    expect(reports).toBe(1); expect(sheets(child)[0].textContent).toBe("a{color:red}");
    source.textContent = "a{color:blue}"; dom.flush(); expect(sheets(child)[0].textContent).toBe(source.textContent);
  } finally { console.error = originalError; dispose(); }
});

test("theme owns only selected names, follows changes/removals, and repairs conflicting child edits", () => {
  const dom = styleDOM(), owner = dom.document().documentElement, child = dom.document().documentElement;
  owner.setAttribute("data-theme", "dark"); owner.setAttribute("data-secret", "not-copied");
  owner.classList.toggle("dark", true); owner.style.setProperty("--accent", "red", "important");
  child.setAttribute("data-theme", "original"); child.classList.toggle("child-local", true);
  const dispose = shareRelatedWindowTheme(owner, child, {attributes:["data-theme"],classes:["dark"],variables:["--accent"]}, () => true);
  expect(child.getAttribute("data-theme")).toBe("dark"); expect(child.hasAttribute("data-secret")).toBe(false);
  expect(child.classList.contains("child-local")).toBe(true); expect(child.style.getPropertyPriority("--accent")).toBe("important");
  child.setAttribute("data-theme", "conflict"); dom.flush(); expect(child.getAttribute("data-theme")).toBe("dark");
  owner.removeAttribute("data-theme"); owner.classList.toggle("dark", false); owner.style.removeProperty("--accent"); dom.flush();
  expect(child.hasAttribute("data-theme")).toBe(false); expect(child.classList.contains("dark")).toBe(false); expect(child.style.getPropertyValue("--accent")).toBe("");
  dispose(); dispose(); expect(child.getAttribute("data-theme")).toBe("original"); expect(dom.observers()).toBe(0);
});

test("theme invalidation drops queued updates; empty selections allocate no observer", () => {
  const dom = styleDOM(), owner = dom.document().documentElement, child = dom.document().documentElement;
  shareRelatedWindowTheme(owner, child, {}, () => true)(); expect(dom.observers()).toBe(0);
  let active = true;
  const dispose = shareRelatedWindowTheme(owner, child, {attributes:["data-theme"]}, () => active);
  owner.setAttribute("data-theme", "late"); active = false; dom.flush();
  expect(child.hasAttribute("data-theme")).toBe(false); expect(dom.observers()).toBe(0); dispose();
});

test("theme selection is snapshotted, deduplicated, and cannot smuggle event handlers or arbitrary attributes", () => {
  const source = {attributes:["data-theme", "data-theme"],classes:["dark"],variables:["--accent"]};
  const result = normalizeRelatedWindowTheme(source); source.attributes[0] = "data-other";
  expect(result?.attributes).toEqual(["data-theme"]);
  for (const value of [{attributes:["onclick"]},{attributes:["style"]},{attributes:["id"]},{attributes:"data-theme"},
    {classes:["a b"]},{variables:["background"]},{all:true}]) expect(() => normalizeRelatedWindowTheme(value)).toThrow(TypeError);
});

test("selected inline theme URL values use the owner's base and recover after unsupported edits", () => {
  const dom = styleDOM(), owner = dom.document().documentElement, child = dom.document("https://example.test/.zapp/related.html").documentElement;
  owner.style.setProperty("--art", "url(./image.png)");
  const dispose = shareRelatedWindowTheme(owner, child, {variables:["--art"]}, () => true);
  expect(child.style.getPropertyValue("--art")).toBe('url("https://example.test/app/image.png")');
  const originalError = console.error; let reports = 0; console.error = () => { reports++; };
  try {
    owner.style.setProperty("--art", 'image("unsupported")'); dom.flush(); dom.flush(); expect(reports).toBe(1);
    expect(child.style.getPropertyValue("--art")).toBe('url("https://example.test/app/image.png")');
    owner.style.setProperty("--art", "none"); dom.flush(); expect(child.style.getPropertyValue("--art")).toBe("none");
  } finally { console.error = originalError; dispose(); }
});
