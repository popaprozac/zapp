// Shared RPC schema between bun and webview.
// Used by both sides so defineRPC stays type-safe.

export type BenchSchema = {
  bun: {
    requests: {
      ping: { params: undefined; response: { pong: number } };
    };
    messages: Record<string, never>;
  };
  webview: {
    requests: Record<string, never>;
    messages: Record<string, never>;
  };
};
