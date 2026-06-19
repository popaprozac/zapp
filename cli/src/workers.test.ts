import { test, expect } from "bun:test";
import { WORKER_PATTERN } from "./workers";

function firstWorkerSpec(src: string): string | null {
  WORKER_PATTERN.lastIndex = 0;
  const m = WORKER_PATTERN.exec(src);
  return m ? (m[1] ?? m[2] ?? null) : null;
}

test("matches new Worker(\"./w.ts\")", () => {
  expect(firstWorkerSpec(`new Worker("./w.ts")`)).toBe("./w.ts");
});
test("matches single-quoted specifier", () => {
  expect(firstWorkerSpec(`new Worker('./a/b.ts')`)).toBe("./a/b.ts");
});
test("matches new URL(..., import.meta.url) form", () => {
  expect(firstWorkerSpec(`new Worker(new URL("./w.ts", import.meta.url))`)).toBe("./w.ts");
});
test("does not match unrelated constructors", () => {
  expect(firstWorkerSpec(`const x = new Foo("y")`)).toBeNull();
});
test("does not match SharedWorker (web-native; not Zapp-bundled)", () => {
  expect(firstWorkerSpec(`new SharedWorker("./s.ts")`)).toBeNull();
});
