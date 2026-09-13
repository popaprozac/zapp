import { expect, test } from "bun:test";
import {
  RelatedWindowEvent,
  RelatedWindowInvalidatedError,
  WindowEvent,
  type RelatedWindowHandle,
  type WindowHandle,
  type WindowEventSubscription,
} from "./window-api";

test("related handle preserves existing controls and typed subscription overloads", () => {
  const compile = (related: RelatedWindowHandle, ordinary: WindowHandle) => {
    const base: WindowHandle = related;
    base.focus();
    related.close();
    const document: Document = related.document;
    document.body.append(document.createElement("section"));
    const invalidated: WindowEventSubscription = related.subscribe(RelatedWindowEvent.INVALIDATED, event => {
      const id: string = event.windowId;
      const reason: string = event.reason;
      void id; void reason;
      // @ts-expect-error Invalidation is terminal, not another close veto.
      event.cancel();
    });
    related.subscribe(WindowEvent.RESIZE, event => void event.size.width);
    related.subscribe(WindowEvent.FOCUS, event => void event.windowId);
    invalidated.unsubscribe();
    // @ts-expect-error Document identity must not be retargeted by callers.
    related.document = document;
    // @ts-expect-error Independent native-window handles do not expose a document.
    void ordinary.document;
    // @ts-expect-error Invalidation belongs to the related-document lifetime.
    ordinary.subscribe(RelatedWindowEvent.INVALIDATED, () => {});
  };
  expect(typeof compile).toBe("function");
});

test("related invalidation error exposes stable classification and document context", () => {
  const error = new RelatedWindowInvalidatedError({ windowId: "win-child", reason: "The document was closed." });
  expect(error.code).toBe("RELATED_WINDOW_INVALIDATED");
  expect(error.windowId).toBe("win-child");
  expect(error.reason).toBe("The document was closed.");
});
