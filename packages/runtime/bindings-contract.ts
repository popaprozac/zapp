export const ZAPP_BINDINGS_SCHEMA_VERSION = 1;

export type ZappServiceBindingMethod = {
  name: string;
  requestType?: string;
  responseType?: string;
  capability?: string;
};

export type ZappServiceBinding = {
  name: string;
  namespace?: string;
  methods: ZappServiceBindingMethod[];
};

export type ZappBindingsManifest = {
  v: typeof ZAPP_BINDINGS_SCHEMA_VERSION;
  generatedAt: string;
  services: ZappServiceBinding[];
};

export const emptyBindingsManifest = (): ZappBindingsManifest => ({
  v: ZAPP_BINDINGS_SCHEMA_VERSION,
  generatedAt: new Date().toISOString(),
  services: [],
});
