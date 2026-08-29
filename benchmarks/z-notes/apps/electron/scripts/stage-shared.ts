import { cp, mkdir } from "node:fs/promises";
import { resolve } from "node:path";

const application = resolve(import.meta.dir, "..");
const shared = resolve(application, "../../shared");
const destination = resolve(application, "src/shared");

await mkdir(destination, { recursive: true });
await Promise.all([
  cp(resolve(shared, "app.css"), resolve(destination, "app.css")),
  cp(resolve(shared, "app.js"), resolve(destination, "app.js")),
]);
