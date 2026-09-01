import { test, expect } from "bun:test";
import {
  ensureViewportFitCover,
  ensureZappServicePathMapping,
} from "./init";

test("adds viewport-fit=cover to a standard vite viewport meta", () => {
  const inp = `<meta name="viewport" content="width=device-width, initial-scale=1.0" />`;
  expect(ensureViewportFitCover(inp)).toContain("viewport-fit=cover");
});

test("is idempotent when viewport-fit already present", () => {
  const inp = `<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />`;
  expect(ensureViewportFitCover(inp)).toBe(inp);
});

test("leaves html without a viewport meta unchanged", () => {
  const inp = `<head><title>x</title></head>`;
  expect(ensureViewportFitCover(inp)).toBe(inp);
});

test("adds zapp:services editor resolution to compiler options", () => {
  const source = `{
  "compilerOptions": {
    "strict": true
  }
}`;
  const mapped = ensureZappServicePathMapping(source);
  expect(mapped).toContain(
    '"zapp:services": ["./.zapp/generated/services.ts"]',
  );
  expect(ensureZappServicePathMapping(mapped)).toBe(mapped);
});

test("extends an existing TypeScript paths map", () => {
  const source = `{
  "compilerOptions": {
    "paths": {
      "@/*": ["./src/*"]
    }
  }
}`;
  const mapped = ensureZappServicePathMapping(source);
  expect(mapped).toContain('"zapp:services"');
  expect(mapped).toContain('"@/*"');
});
