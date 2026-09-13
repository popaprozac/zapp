import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { RelatedDocuments, RelatedDocumentIdentity } from "./related-documents.zs";

// One native endpoint, many successive documents. Platform callbacks validate
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

  internal constructor(windowId: i32, documents: RelatedDocuments, capabilities: CapabilitySelection) {
    this.windowId = windowId;
    this.documents = documents;
    this.capabilities = capabilities;
    this.identity = Option.none;
    this.realm = "";
    this.token = "";
    this.committed = false;
    this.closed = false;
  }

  function retire(inout this): void {
    match (copy this.identity) {
      some(identity) => { const retired = this.documents.retire(in identity); }
      none => {}
    }
    this.identity = Option.none;
    this.realm = "";
    this.token = "";
    this.committed = false;
  }

  function didCommit(inout this): void {
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
      some(identity) => return Option.some(copy identity);
      none => {}
    }
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
        if (this.token != token) return false;
        this.realm = move realm;
        this.documents.observeDocument(in identity);
        select this.documents.observeBridge(in identity);
      }
      none => false;
    };
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
