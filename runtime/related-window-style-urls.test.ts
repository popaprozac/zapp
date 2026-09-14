import { expect, test } from "bun:test";
import { rebaseStyleURLs } from "./related-window-style-urls";
const base = "https://example.test/app/index.html";
test("rebases relative, root, and quoted URLs without changing document fragments", () => {
  expect(rebaseStyleURLs('a{a:url(../a.png);b:url("/font.woff2");c:url(#clip)}', base))
    .toBe('a{a:url("https://example.test/a.png");b:url("https://example.test/font.woff2");c:url("#clip")}');
});
test("preserves strings/comments and parses quoted parentheses and CSS escapes", () => {
  expect(rebaseStyleURLs('/* url(no) */ a{content:"url(no)";b:u\\72l(./a\\ b.png);c:url("x(1).png")}', base))
    .toBe('/* url(no) */ a{content:"url(no)";b:url("https://example.test/app/a%20b.png");c:url("https://example.test/app/x(1).png")}');
});
test("rebases string and url imports, preserving media/layer suffixes", () => {
  expect(rebaseStyleURLs('@import /* hi */ "./theme.css" layer(theme); @import url(./print.css) print;', base))
    .toBe('@import /* hi */ "https://example.test/app/theme.css" layer(theme); @import url("https://example.test/app/print.css") print;');
});
test("keeps data URLs, empty URLs, and escaped punctuation well formed", () => {
  expect(rebaseStyleURLs('a{a:url("data:image/svg+xml,%3Csvg/%3E");b:url();c:url(x\\)y.png)}', base))
    .toBe('a{a:url("data:image/svg+xml,%3Csvg/%3E");b:url("");c:url("https://example.test/app/x)y.png")}');
});
test("supports custom protocol bases without rebasing strings that are not URLs", () => {
  expect(rebaseStyleURLs('a{--label:"./hello";src:url(./font.woff2)}', 'zapp://app/index.html'))
    .toBe('a{--label:"./hello";src:url("zapp://app/font.woff2")}');
});
test("fails explicitly for unsupported URL functions and malformed input", () => {
  for (const source of ['a{a:image("x.png")}', 'a{a:url(unclosed}', '/* unterminated', 'a{content:"unterminated']) {
    expect(() => rebaseStyleURLs(source, base)).toThrow("Related window styles:");
  }
});

test("rebases image-set candidates but not type descriptors or other strings", () => {
  expect(rebaseStyleURLs('a{background:image-set("small.png" 1x type("image/png"), url(big.png) 2x)}', base))
    .toBe('a{background:image-set("https://example.test/app/small.png" 1x type("image/png"), url("https://example.test/app/big.png") 2x)}');
});
test("handles escaped function names and nested gradients without rewriting color strings", () => {
  expect(rebaseStyleURLs('a{background:-webkit-image-set("a.png" 1x, linear-gradient(red, blue) 2x);content:"a.png"}', base))
    .toBe('a{background:-webkit-image-set("https://example.test/app/a.png" 1x, linear-gradient(red, blue) 2x);content:"a.png"}');
});
