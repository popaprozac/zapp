import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { RelatedDocuments, RelatedDocumentIdentity } from "./related-documents.zs";

internal type BridgeDocumentActivated = (identity: RelatedDocumentIdentity) => void on thread.main;
function ignoreActivation(identity: RelatedDocumentIdentity): void on thread.main {}

// Root endpoints can host successive documents; related endpoints are terminal
// after replacement. Platform callbacks validate
// sender/frame/origin before offering, acknowledging, or accepting a token.
// Realm names only target handshake JS; they never select authority.
internal class BridgeDocument on thread.main {
  readonly windowId: i32;
  readonly documents: RelatedDocuments;
  readonly capabilities: CapabilitySelection;
  private identity: Option<RelatedDocumentIdentity>;
  private realm: String;
  private token: String;
  private committed: boolean;
  private closed: boolean;
  private related: boolean;
  private activated: boolean;
  private activationHandler: BridgeDocumentActivated;

  internal constructor(windowId: i32, documents: RelatedDocuments, capabilities: CapabilitySelection) {
    this.windowId = windowId;
    this.documents = documents;
    this.capabilities = capabilities;
    this.identity = Option.none;
    this.realm = "";
    this.token = "";
    this.committed = false;
    this.closed = false;
    this.related = false;
    this.activated = false;
    this.activationHandler = ignoreActivation;
  }

  // A child can inherit only a live, ready native owner's authority. Reserve its
  // identity before creating native resources so owner retirement includes it.
  static function beginRelated(
    windowId: i32,
    documents: RelatedDocuments,
    in owner: RelatedDocumentIdentity
  ): Option<BridgeDocument> on thread.main {
    const capabilities = match (documents.capabilitiesFor(in owner)) {
      some(value) => value;
      none => return Option.none;
    };
    const identity = match (documents.beginRelated(in owner, windowId)) {
      some(value) => value;
      none => return Option.none;
    };
    const endpoint = new BridgeDocument(windowId, documents, capabilities);
    endpoint.adoptRelated(identity);
    return Option.some(endpoint);
  }

  private function adoptRelated(inout this, identity: RelatedDocumentIdentity): void {
    this.related = true;
    this.token = `${identity.token}`;
    this.identity = Option.some(identity);
  }

  function requiresShell(): boolean { return this.related; }

  // Native-only notification. A renderer cannot select this callback or use
  // its realm/token as authority. Install before returning the child WebView.
  function whenActivated(inout this, handler: BridgeDocumentActivated): boolean {
    if (!this.related || this.closed || this.activated) return false;
    this.activationHandler = handler;
    return true;
  }

  // Native creation bookkeeping may identify a reserved child before readiness.
  // This is not an acceptance path for renderer messages.
  function creationIdentity(): Option<RelatedDocumentIdentity> {
    if (!this.related || this.closed) return Option.none;
    return match (in this.identity) {
      some(identity) => this.documents.isLive(in identity) ? Option.some(copy identity) : Option.none;
      none => Option.none;
    };
  }

  function retire(inout this): void {
    if (this.related) this.closed = true;
    match (copy this.identity) {
      some(identity) => { const retired = this.documents.retire(in identity); }
      none => {}
    }
    this.identity = Option.none;
    this.realm = "";
    this.token = "";
    this.committed = false;
    this.activated = false;
    this.activationHandler = ignoreActivation;
  }

  function didCommit(inout this): void {
    if (this.closed) return;
    if (this.related && !this.committed) {
      this.committed = true;
      return;
    }
    this.retire();
    if (!this.closed) this.committed = true;
  }

  function close(inout this): void {
    this.closed = true;
    this.retire();
  }

  function offer(inout this, in realm: String): Option<RelatedDocumentIdentity> {
    if (this.closed || !this.committed) return Option.none;
    if (this.realm.byteLength != 0 && this.realm != realm) return Option.none;
    match (copy this.identity) {
      some(identity) => {
        if (!this.documents.isLive(in identity)) return Option.none;
        return Option.some(copy identity);
      }
      none => {}
    }
    if (this.related) return Option.none;
    const documents = this.documents;
    this.identity = documents.beginOwner(this.windowId, this.capabilities);
    this.token = match (in this.identity) { some(identity) => `${identity.token}`; none => ""; };
    return copy this.identity;
  }

  function acknowledge(inout this, in token: String, realm: String): boolean {
    if (this.closed || !this.committed) return false;
    if (this.realm.byteLength != 0 && this.realm != realm) return false;
    return match (copy this.identity) {
      some(identity) => {
        if (this.token != token || !this.documents.isLive(in identity)) return false;
        this.realm = move realm;
        if (!this.related) this.documents.observeDocument(in identity);
        select this.documents.observeBridge(in identity);
      }
      none => false;
    };
  }

  function bindingMatches(in token: String, in realm: String): boolean {
    if (this.closed || !this.committed || this.token != token
      || this.realm.byteLength == 0 || this.realm != realm) return false;
    return match (in this.identity) {
      some(identity) => this.documents.isLive(in identity);
      none => false;
    };
  }

  // Called only after the native host has evaluated the matching realm/token
  // and usable head/body. A bridge acknowledgement alone cannot expose a child.
  function observeShell(in token: String, in realm: String): boolean {
    if (!this.related || !this.bindingMatches(in token, in realm)) return false;
    return match (in this.identity) {
      some(identity) => this.documents.observeDocument(in identity);
      none => false;
    };
  }

  // Registry readiness permits calls flushed by _activateDocument. Creation
  // completion is stricter: the native evaluateJavaScript reply must confirm
  // that activation succeeded for this still-current realm and document.
  function observeActivation(inout this, in token: String, in realm: String): boolean {
    if (!this.related || this.activated || !this.bindingMatches(in token, in realm)) return false;
    const identity = match (this.accept(in token)) { some(value) => value; none => return false; };
    this.activated = true;
    const handler = this.activationHandler;
    this.activationHandler = ignoreActivation;
    handler(identity);
    return true;
  }

  function isActivated(in identity: RelatedDocumentIdentity): boolean {
    return this.activated && this.isCurrent(in identity);
  }

  function accept(in token: String): Option<RelatedDocumentIdentity> {
    if (this.closed || !this.committed) return Option.none;
    return match (in this.identity) {
      some(identity) => {
        if (this.token != token || !this.documents.isReady(in identity)) {
          return Option<RelatedDocumentIdentity>.none;
        }
        select Option.some(copy identity);
      }
      none => Option.none;
    };
  }

  function isCurrent(in identity: RelatedDocumentIdentity): boolean {
    return !this.closed && this.documents.isReady(in identity)
      && identity.windowId == this.windowId;
  }
}
