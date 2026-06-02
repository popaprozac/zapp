// Pure helpers that turn a Zen-C service handler into TypeScript types for
// the generated wrapper. No I/O — every function takes strings and returns
// data, so they are unit-testable in isolation (see service-types.test.ts).

export interface ArgField {
  name: string;
  tsType: string; // "string" | "number" | "boolean" | "unknown"
}

const TYPE_MAP: Record<string, string> = {
  string: "string",
  int: "number",
  float: "number",
  bool: "boolean",
};

// Matches `args.get_string("k")` / `get_int` / `get_float` / `get_bool`, OR
// the generic nested accessor `args.get("k")`. Group 1 = the primitive
// accessor suffix (undefined for the generic get); group 2 = key for the
// primitive form; group 3 = key for the generic form.
const ACCESSOR_RE =
  /\bargs\.get_(string|int|float|bool)\s*\(\s*"([^"]+)"\s*\)|\bargs\.get\s*\(\s*"([^"]+)"\s*\)/g;

// Scan a handler body for arg accessors → ordered, de-duplicated fields.
// First occurrence of a key wins; a conflicting later type warns and is dropped.
export function inferArgs(body: string): ArgField[] {
  const fields = new Map<string, string>();
  ACCESSOR_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = ACCESSOR_RE.exec(body)) !== null) {
    const accessor = m[1]; // undefined for the generic `.get(...)`
    const key = m[2] ?? m[3];
    const tsType = accessor ? TYPE_MAP[accessor] : "unknown";
    const existing = fields.get(key);
    if (existing === undefined) {
      fields.set(key, tsType);
    } else if (existing !== tsType) {
      console.warn(
        `[zapp] service arg "${key}" is read as both ${existing} and ${tsType}; keeping ${existing}.`
      );
    }
  }
  return [...fields].map(([name, tsType]) => ({ name, tsType }));
}

export interface Annotation {
  argsFragment?: string;
  returnsFragment?: string;
}

// Extract the balanced-brace { … } fragment that follows `keyword` in `text`.
// Returns undefined if the keyword is absent or its braces are unbalanced.
function extractFragment(text: string, keyword: string): string | undefined {
  const at = text.indexOf(keyword);
  if (at === -1) return undefined;
  const after = text.slice(at + keyword.length);
  const open = after.indexOf("{");
  if (open === -1) return undefined;
  let depth = 0;
  for (let i = open; i < after.length; i++) {
    if (after[i] === "{") depth++;
    else if (after[i] === "}") {
      depth--;
      if (depth === 0) return after.slice(open, i + 1).trim();
    }
  }
  return undefined; // unbalanced
}

// Parse the comment block above a handler for @zapp:args / @zapp:returns.
// Line-comment markers are stripped first so the brace scan ignores them.
export function parseAnnotation(commentBlock: string): Annotation {
  const text = commentBlock.replace(/^\s*\/\/+/gm, " ");
  const result: Annotation = {};
  const returns = extractFragment(text, "@zapp:returns");
  const args = extractFragment(text, "@zapp:args");
  if (returns !== undefined) result.returnsFragment = returns;
  if (args !== undefined) result.argsFragment = args;
  return result;
}

export interface HandlerSlice {
  commentBlock: string; // contiguous // lines directly above the fn ("" if none)
  body: string;         // brace-matched function body, including the outer { }
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Locate `fn <handlerName>(` in Zen-C source. Returns its preceding comment
// block (contiguous // lines, blank lines between fn and comment tolerated)
// and its brace-matched body. Returns null if the handler isn't found.
export function extractHandler(content: string, handlerName: string): HandlerSlice | null {
  const fnRe = new RegExp(`\\bfn\\s+${escapeRegExp(handlerName)}\\s*\\(`, "g");
  const m = fnRe.exec(content);
  if (!m) return null;
  const fnStart = m.index;

  // Walk backwards over the lines before `fn`, collecting contiguous // lines.
  const lines = content.slice(0, fnStart).split("\n");
  const commentLines: string[] = [];
  for (let i = lines.length - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (t === "") {
      if (commentLines.length === 0) continue; // whitespace between fn and comment
      break; // blank line ends an earlier comment block
    }
    if (t.startsWith("//")) commentLines.unshift(lines[i]);
    else break;
  }
  const commentBlock = commentLines.join("\n");

  // Brace-match the body from the first { after the signature.
  let body = "";
  const open = content.indexOf("{", fnStart);
  if (open !== -1) {
    let depth = 0;
    for (let i = open; i < content.length; i++) {
      if (content[i] === "{") depth++;
      else if (content[i] === "}") {
        depth--;
        if (depth === 0) {
          body = content.slice(open, i + 1);
          break;
        }
      }
    }
  }
  return { commentBlock, body };
}

export interface ServiceTypeDecls {
  argsDecl: string;   // full `export interface XxxArgs { … }` or `export type XxxArgs = …;`
  resultDecl: string; // full `export interface XxxResult { … }` or `export type XxxResult = …;`
  argsName: string;   // "XxxArgs"
  resultName: string; // "XxxResult"
}

function fieldsToBody(fields: ArgField[]): string {
  return "{ " + fields.map((f) => `${f.name}?: ${f.tsType}`).join("; ") + " }";
}

// Resolve the args + result type declarations for one service. `fileName` is
// the PascalCase base (e.g. "Greet"); `content` is the full .zc source the
// handler lives in; `handlerName` is the Zen-C fn name.
//
// Precedence — args: @zapp:args override > inferred fields > loose.
//              result: @zapp:returns annotation > loose (unknown).
export function resolveServiceTypes(
  fileName: string,
  content: string,
  handlerName: string
): ServiceTypeDecls {
  const argsName = `${fileName}Args`;
  const resultName = `${fileName}Result`;
  const slice = extractHandler(content, handlerName);
  const ann = slice ? parseAnnotation(slice.commentBlock) : {};

  let argsDecl: string;
  if (ann.argsFragment) {
    argsDecl = `export interface ${argsName} ${ann.argsFragment}`;
  } else {
    const fields = slice ? inferArgs(slice.body) : [];
    argsDecl =
      fields.length > 0
        ? `export interface ${argsName} ${fieldsToBody(fields)}`
        : `export type ${argsName} = Record<string, unknown>;`;
  }

  const resultDecl = ann.returnsFragment
    ? `export interface ${resultName} ${ann.returnsFragment}`
    : `export type ${resultName} = unknown;`;

  return { argsDecl, resultDecl, argsName, resultName };
}

// Render the full TypeScript binding file content for one service.
// `serviceName` is the raw service name (the invoke() string), `fnName` is
// the JS identifier (camelCased), `decls` are the resolved type declarations.
export function renderTsBinding(
  serviceName: string,
  fnName: string,
  decls: ServiceTypeDecls
): string {
  return `import { Services } from "@zappdev/runtime";

${decls.argsDecl}
${decls.resultDecl}

export async function ${fnName}(args?: ${decls.argsName}): Promise<${decls.resultName}> {
    return Services.invoke<${decls.resultName}, ${decls.argsName}>("${serviceName}", args ?? ({} as ${decls.argsName}));
}
`;
}
