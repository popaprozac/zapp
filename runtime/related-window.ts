import { getBridge, type ZappBridge } from "./bridge";
import { ensurePermission } from "./permissions";
import { WindowError } from "./window-errors";
import { bindRelatedDocumentLifetime, type RelatedDocumentLifetime } from "./related-window-lifetime";
import type { RelatedWindowCreateOptions } from "./related-window-contract";

interface DocumentBridge extends ZappBridge {
  _dispose(error: Error): void;
  _observeRelatedDocument(id: string, token: string, invalidated: (reason: string) => void, created: () => void): () => void;
}
interface Prepared { windowId: string; documentToken: string; nativeId: number; address: string; }

/** @internal No frontend owner, profile, URL, or navigation override crosses here. */
function optionsForNative(options: RelatedWindowCreateOptions): Record<string, unknown> {
  if (!options || typeof options !== "object" || Array.isArray(options)
    || Object.keys(options).some(key => !["title", "width", "height"].includes(key))) {
    throw new TypeError("Related windows accept only title, width, and height.");
  }
  if (options.title !== undefined && typeof options.title !== "string") throw new TypeError("Related window title must be a string.");
  for (const key of ["width", "height"] as const) {
    const value = options[key];
    if (value !== undefined && (!Number.isInteger(value) || value < 1 || value > 0xffff_ffff)) {
      throw new TypeError(`Related window ${key} must be a positive u32 integer.`);
    }
  }
  return { ...options };
}

function creationError(message: string): WindowError { return new WindowError({ operation: "create", message }); }

function preparedIdentity(value: unknown): Prepared {
  const result = value as Prepared | undefined;
  if (!result || !Number.isInteger(result.nativeId) || result.nativeId < 1 || result.nativeId > 0x7fff_ffff
    || result.windowId !== `related-${result.nativeId}` || typeof result.documentToken !== "string"
    || !/^[1-9][0-9]{0,19}$/.test(result.documentToken)) {
    throw creationError("Native related-window preparation returned an invalid identity.");
  }
  return result;
}

/** @internal Returned only after native activation and publication. */
export interface RelatedWindowBinding {
  readonly id: string;
  readonly document: Document;
  readonly bridge: ZappBridge;
  readonly lifetime: RelatedDocumentLifetime;
}

/**
 * @internal Prepare → observe → open → activated → publish. Native's original
 * deadline remains armed until publication. No interval polling and no second
 * registry on ordinary service calls. Shell readiness is not first paint.
 */
export async function createRelatedWindowBinding(options: RelatedWindowCreateOptions, activationTimeoutMs = 15_000): Promise<RelatedWindowBinding> {
  const wireOptions = optionsForNative(options);
  ensurePermission("window:create");
  const owner = getBridge() as DocumentBridge;
  if (typeof owner._observeRelatedDocument !== "function") throw creationError("Related windows are unavailable in this host.");
  const prepared = preparedIdentity(await owner.invoke("__window:prepare-related", wireOptions));
  const correlation = { nativeId: prepared.nativeId, documentToken: prepared.documentToken };
  let childBridge: DocumentBridge | undefined;
  let stopObserving: (() => void) | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let rejectReady: (error: unknown) => void = () => {};
  const lifetime = bindRelatedDocumentLifetime(prepared, { _dispose(error) {
    childBridge?._dispose(error);
    rejectReady(error);
  } });
  try {
    // Custom schemes have opaque URL.origin ("null"); compare the full tuple.
    const address = new URL(prepared.address);
    const origin = new URL(window.location.href);
    if (typeof prepared.address !== "string" || address.protocol !== origin.protocol
      || address.host !== origin.host || address.username || address.password
      || address.pathname !== "/.zapp/related.html" || address.hash
      || address.search !== `?creation=${prepared.documentToken}`) {
      throw creationError("Native related-window preparation returned an invalid shell address.");
    }
    let ready!: () => void;
    const activated = new Promise<void>((resolve, reject) => { ready = resolve; rejectReady = reject; });
    // Install the rejection handler before opening: test/native hooks may fail
    // synchronously and a thrown open() must not leave an unhandled rejection.
    void activated.catch(() => {});
    stopObserving = owner._observeRelatedDocument(prepared.windowId, prepared.documentToken,
      reason => lifetime.invalidate(prepared, reason), ready);
    timer = setTimeout(() => rejectReady(creationError("Related window activation timed out.")), activationTimeoutMs);
    lifetime.assertActive();
    const child = window.open(prepared.address);
    if (!child) throw creationError("The native host did not create the related window.");
    await activated;
    lifetime.assertActive();
    if (child.closed || !child.document.head || !child.document.body
      || (child as any)[Symbol.for("zapp.windowId")] !== prepared.windowId) {
      throw creationError("The related document was not available after activation.");
    }
    const candidate = (child as any)[Symbol.for("zapp.bridge")];
    if (!candidate || candidate === owner || typeof candidate.invoke !== "function"
      || typeof candidate._dispose !== "function") throw creationError("The related document did not receive its native bridge.");
    childBridge = candidate;
    const document = child.document;
    await owner.invoke("__window:publish-related", correlation);
    lifetime.assertActive();
    if (child.closed || child.document !== document) throw creationError("The related document changed during publication.");
    return { id: prepared.windowId, document, bridge: childBridge!, lifetime };
  } catch (error) {
    lifetime.invalidate(prepared, "Related window creation did not complete.");
    stopObserving?.();
    // Native rollback is synchronous before acknowledgement. If the owner was
    // retired, its native family teardown already owns this cleanup instead.
    try { await owner.invoke("__window:abort-related", correlation); } catch {}
    throw error;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    rejectReady = () => {};
  }
}
