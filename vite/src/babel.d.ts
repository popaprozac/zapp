// Babel's CommonJS packages do not publish TypeScript declarations. The Vite
// plugin loads them dynamically and treats their plugin API as an opaque build
// dependency.
declare module "@babel/core";
declare module "@babel/plugin-transform-classes";
