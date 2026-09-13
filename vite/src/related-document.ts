import type { IncomingMessage, ServerResponse } from "node:http";
import {
  RELATED_DOCUMENT_SHELL_HTML,
  RELATED_DOCUMENT_SHELL_PATH,
} from "../../bootstrap/related-document";

// Runs before Vite's HTML fallback/transforms. A related child must not reload
// the application's entry or gain a second HMR/client bootstrap of its own.
export function serveRelatedDocumentShell(
  request: IncomingMessage,
  response: ServerResponse,
  next: () => void,
): void {
  if (request.url?.split("?", 1)[0] !== RELATED_DOCUMENT_SHELL_PATH) {
    next();
    return;
  }
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("X-Content-Type-Options", "nosniff");
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.statusCode = 405;
    response.setHeader("Allow", "GET, HEAD");
    response.end();
    return;
  }
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  response.setHeader("Content-Length", Buffer.byteLength(RELATED_DOCUMENT_SHELL_HTML));
  response.end(request.method === "HEAD" ? undefined : RELATED_DOCUMENT_SHELL_HTML);
}
