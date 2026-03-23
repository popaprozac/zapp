/** Current version of the bindings schema format. */
export const ZAPP_BINDINGS_SCHEMA_VERSION = 1;

/** Describes a single method exposed by a service binding. */
export type ZappServiceBindingMethod = {
  name: string;
  requestType?: string;
  responseType?: string;
  capability?: string;
};

/** Describes a service and the methods it exposes. */
export type ZappServiceBinding = {
  name: string;
  namespace?: string;
  methods: ZappServiceBindingMethod[];
};

/** Top-level manifest listing all available service bindings. */
export type ZappBindingsManifest = {
  v: typeof ZAPP_BINDINGS_SCHEMA_VERSION;
  generatedAt: string;
  services: ZappServiceBinding[];
};

/** Create an empty bindings manifest with the current schema version. */
export const emptyBindingsManifest = (): ZappBindingsManifest => ({
  v: ZAPP_BINDINGS_SCHEMA_VERSION,
  generatedAt: new Date().toISOString(),
  services: [],
});
