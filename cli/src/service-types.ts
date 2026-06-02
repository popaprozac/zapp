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
