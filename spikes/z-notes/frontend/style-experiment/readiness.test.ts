import { expect, test } from 'bun:test';
import { createStylesheetReadiness } from './readiness';
class Link extends EventTarget { sheet: CSSStyleSheet | null = null; }
test('stylesheet snapshot waits for every pending link and releases listeners', async () => {
  const tracker = createStylesheetReadiness(), a = new Link(), b = new Link();
  tracker.watch(a); tracker.watch(b); const waiting = tracker.ready(100);
  a.dispatchEvent(new Event('load')); expect(tracker.stats().waits).toBe(1);
  b.dispatchEvent(new Event('load')); expect(await waiting).toBe('ready');
  expect(tracker.stats()).toEqual({links:2,listeners:0,waits:0}); tracker.dispose();
});
test('a failed link fails promptly even if another never completes', async () => {
  const tracker = createStylesheetReadiness(), a = new Link(); tracker.watch(a); tracker.watch(new Link());
  const waiting = tracker.ready(100); a.dispatchEvent(new Event('error'));
  expect(await waiting).toBe('failed'); expect(tracker.stats().waits).toBe(0); tracker.dispose();
});
test('timeout does not accumulate promise reactions or active waiter records', async () => {
  const tracker = createStylesheetReadiness(); tracker.watch(new Link());
  for (let i = 0; i < 10; i++) { expect(await tracker.ready(0)).toBe('timeout'); expect(tracker.stats().waits).toBe(0); }
  expect(tracker.stats().listeners).toBe(2); tracker.dispose();
  expect(tracker.stats()).toEqual({links:0,listeners:0,waits:0});
});
test('retargeting a tracked link invalidates a pending snapshot', async () => {
  const tracker = createStylesheetReadiness(), a = new Link(), b = new Link(); tracker.watch(a);
  const waiting = tracker.ready(100); tracker.forget(a); tracker.watch(b);
  expect(await waiting).toBe('changed');
  const newer = tracker.ready(100);
  a.dispatchEvent(new Event('load')); a.dispatchEvent(new Event('error'));
  expect(tracker.stats()).toEqual({links:1,listeners:2,waits:1});
  b.dispatchEvent(new Event('load')); expect(await newer).toBe('ready'); tracker.dispose();
});
test('disposal settles waiters and ignores late events', async () => {
  const tracker = createStylesheetReadiness(), a = new Link(); tracker.watch(a);
  const waiting = tracker.ready(100); tracker.dispose(); tracker.dispose();
  a.dispatchEvent(new Event('load')); a.dispatchEvent(new Event('error'));
  expect(await waiting).toBe('disposed'); expect(await tracker.ready(100)).toBe('disposed');
  expect(tracker.stats()).toEqual({links:0,listeners:0,waits:0});
});
test('empty and already-loaded snapshots resolve; invalid bounds are rejected', async () => {
  const tracker = createStylesheetReadiness(); expect(await tracker.ready(100)).toBe('ready');
  const a = new Link(); a.sheet = {} as CSSStyleSheet; tracker.watch(a); expect(await tracker.ready(100)).toBe('ready');
  expect(() => tracker.ready(Infinity)).toThrow(); expect(() => tracker.ready(-1)).toThrow(); tracker.dispose();
});
