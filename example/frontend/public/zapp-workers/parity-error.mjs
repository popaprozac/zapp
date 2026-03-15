// src/parity-error.ts
setTimeout(() => {
  throw new Error("parity worker boom");
}, 25);
