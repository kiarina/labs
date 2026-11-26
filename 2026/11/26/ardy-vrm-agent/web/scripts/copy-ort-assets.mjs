// Copies the ONNX Runtime Web host assets that `onnxruntime-web/webgpu`
// loads at runtime (the same two files ARDY Mini ships) into public/ort/.
import { copyFile, mkdir } from "node:fs/promises";

const dist = new URL("../node_modules/onnxruntime-web/dist/", import.meta.url);
const destination = new URL("../public/ort/", import.meta.url);
await mkdir(destination, { recursive: true });
for (const name of [
  "ort-wasm-simd-threaded.asyncify.mjs",
  "ort-wasm-simd-threaded.asyncify.wasm",
]) {
  await copyFile(new URL(name, dist), new URL(name, destination));
}
