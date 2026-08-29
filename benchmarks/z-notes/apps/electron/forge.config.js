const path = require("node:path");

module.exports = {
  packagerConfig: {
    asar: true,
    icon: path.resolve(__dirname, "../../../../assets/zapp.png"),
  },
  rebuildConfig: {},
  makers: [],
  plugins: [
    {
      name: "@electron-forge/plugin-auto-unpack-natives",
      config: {},
    },
  ],
};
