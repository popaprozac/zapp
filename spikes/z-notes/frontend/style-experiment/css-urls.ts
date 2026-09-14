// Private experiment, not a general CSS parser. Rebase ordinary URL forms
// without matching url(...) text inside strings/comments. CSSOM is a later tier.
function escapeEnd(text: string, start: number): number {
  let i = start + 1;
  if (/[0-9a-f]/i.test(text[i] ?? "")) {
    let count = 0;
    while (count++ < 6 && /[0-9a-f]/i.test(text[i] ?? "")) i++;
    if (text[i] === "\r" && text[i + 1] === "\n") return i + 2;
    return /\s/.test(text[i] ?? "") ? i + 1 : i;
  }
  return text[i] === "\r" && text[i + 1] === "\n" ? i + 2 : Math.min(i + 1, text.length);
}
function unescapeCSS(text: string): string {
  return text.replace(/\\(?:([0-9a-f]{1,6})(?:\r\n|[\t\n\r\f ])?|(\r\n|[\n\r\f])|([^\n\r\f]))/gi,
    (_match, hex: string | undefined, newline: string | undefined, char: string | undefined) => {
      if (hex) {
        const code = parseInt(hex, 16);
        return String.fromCodePoint(code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? 0xfffd : code);
      }
      return newline ? "" : char ?? "";
    });
}
function quote(text: string): string {
  return '"' + text.replace(/[\\"\n\r\f]/g, char => char === "\\" || char === '"' ? "\\" + char : "\\" + char.charCodeAt(0).toString(16) + " ") + '"';
}
function stringEnd(text: string, start: number): number {
  const delimiter = text[start];
  for (let i = start + 1; i < text.length;) {
    if (text[i] === delimiter) return i + 1;
    if (text[i] === "\\") i = escapeEnd(text, i); else i++;
  }
  throw new Error("Style experiment: unterminated CSS string");
}
function nameEnd(text: string, start: number): number {
  let i = start;
  while (i < text.length) {
    if (text[i] === "\\") i = escapeEnd(text, i);
    else if (/[\w\u0080-\uffff-]/.test(text[i])) i++;
    else break;
  }
  return i;
}
function spaceEnd(text: string, start: number): number {
  let i = start;
  while (i < text.length) {
    if (/\s/.test(text[i])) { i++; continue; }
    if (text.startsWith("/*", i)) {
      const end = text.indexOf("*/", i + 2);
      if (end < 0) throw new Error("Style experiment: unterminated CSS comment");
      i = end + 2; continue;
    }
    break;
  }
  return i;
}
export function rebaseStyleURLs(text: string, base: string): string {
  const resolve = (raw: string) => {
    const value = unescapeCSS(raw);
    // Fragment-only SVG/filter references belong to the destination document.
    return quote(!value || value.startsWith("#") ? value : new URL(value, base).href);
  };
  let output = "";
  for (let i = 0; i < text.length;) {
    if (text.startsWith("/*", i)) {
      const end = spaceEnd(text, i); output += text.slice(i, end); i = end; continue;
    }
    if (text[i] === '"' || text[i] === "'") {
      const end = stringEnd(text, i); output += text.slice(i, end); i = end; continue;
    }
    if (text[i] === "@") {
      const end = nameEnd(text, i + 1);
      if (unescapeCSS(text.slice(i + 1, end)).toLowerCase() === "import") {
        const start = spaceEnd(text, end);
        if (text[start] === '"' || text[start] === "'") {
          const finish = stringEnd(text, start);
          output += text.slice(i, start) + resolve(text.slice(start + 1, finish - 1)); i = finish; continue;
        }
      }
      output += text.slice(i, end); i = end; continue;
    }
    if (/[\w\u0080-\uffff-]/.test(text[i]) || text[i] === "\\") {
      const end = nameEnd(text, i);
      const name = unescapeCSS(text.slice(i, end)).toLowerCase();
      if ((name === "image-set" || name === "-webkit-image-set") && text[end] === "(") {
        throw new Error("Style experiment: image-set URL rewriting is not implemented");
      }
      if (name === "url" && text[end] === "(") {
        const start = spaceEnd(text, end + 1);
        let finish: number, value: string;
        if (text[start] === '"' || text[start] === "'") {
          const close = stringEnd(text, start);
          value = text.slice(start + 1, close - 1); finish = spaceEnd(text, close);
        } else {
          finish = start;
          while (finish < text.length && text[finish] !== ")") {
            if (/\s/.test(text[finish]) || text.startsWith("/*", finish)) break;
            if (text[finish] === "\\") finish = escapeEnd(text, finish); else finish++;
          }
          value = text.slice(start, finish); finish = spaceEnd(text, finish);
        }
        if (text[finish] !== ")") throw new Error("Style experiment: unsupported or malformed CSS url()");
        output += "url(" + resolve(value) + ")"; i = finish + 1; continue;
      }
      output += text.slice(i, end); i = end; continue;
    }
    output += text[i++];
  }
  return output;
}
