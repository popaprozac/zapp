// Keep the in-repository application self-contained. `zapp dev` supplies Vite
// through the CLI, while an ordinary generated application declares Vite in
// its own package.json and may use `defineConfig` for richer typing.
export default {
  root: "frontend",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
};
