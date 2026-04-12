// Minimal forge config for the benchmark: just package the Electron binary
// into a .app bundle. No fuses, no installers, no signing — the benchmark
// only needs a launchable release build. Electron's default fuses plugin
// enables asar-integrity validation which requires full code signing to
// pass runtime checks; adhoc signing (the default) fails the check and
// v8 aborts during snapshot deserialization. Dropping the plugin keeps
// things launchable out of the box, which is all we need.
module.exports = {
  packagerConfig: {
    asar: true,
  },
  rebuildConfig: {},
  makers: [],
  plugins: [
    {
      name: '@electron-forge/plugin-auto-unpack-natives',
      config: {},
    },
  ],
};
