import { createReadStream, existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { execFileSync } from "node:child_process";
import { chromium } from "playwright-core";

const root = process.cwd();
const repositoryRoot = normalize(join(root, "../../../.."));
const mime = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript",
  ".png": "image/png", ".jpg": "image/jpeg", ".glb": "model/gltf-binary",
};
const server = createServer((request, response) => {
  const relative = decodeURIComponent((request.url || "/").split("?")[0]).replace(/^\/+/, "") || "viewer.html";
  const path = normalize(join(repositoryRoot, relative));
  if (!path.startsWith(repositoryRoot) || !existsSync(path)) {
    response.writeHead(404).end("not found"); return;
  }
  response.setHeader("Content-Type", mime[extname(path)] || "application/octet-stream");
  createReadStream(path).pipe(response);
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const { port } = server.address();

const chromeApp = execFileSync("mdfind", ["kMDItemCFBundleIdentifier == 'com.google.Chrome'"], { encoding: "utf8" })
  .split("\n").find(Boolean);
const chromePath = process.env.CHROME_PATH || (chromeApp && join(chromeApp, "Contents", "MacOS", "Google Chrome"));
if (!chromePath || !existsSync(chromePath)) throw new Error("Google Chrome not found; set CHROME_PATH");
const browser = await chromium.launch({
  executablePath: chromePath,
  headless: true,
});
const page = await browser.newPage({ viewport: { width: 720, height: 720 }, deviceScaleFactor: 1 });

async function load(name, kind) {
  await page.goto(`http://127.0.0.1:${port}/2026/07/11/anigen-mac/viewer.html?case=${name}&kind=${kind}`);
  await page.locator("model-viewer").evaluate(element => element.updateComplete);
  await page.locator("model-viewer").evaluate(element => new Promise((resolve, reject) => {
    if (element.loaded) return resolve();
    element.addEventListener("load", resolve, { once: true });
    element.addEventListener("error", reject, { once: true });
  }));
  await page.waitForTimeout(500);
}

await mkdir(join(root, "preview", "renders"), { recursive: true });
const rendered = [];
for (const name of ["miineko1", "miineko2"]) {
  if (!existsSync(join(root, "results", name, "mesh.glb")) ||
      !existsSync(join(root, "results", name, "skeleton.glb"))) {
    continue;
  }
  for (const kind of ["mesh", "skeleton"]) {
    await load(name, kind);
    await page.locator("model-viewer").screenshot({
      path: join(root, "preview", "renders", `${name}-${kind}.png`),
    });
  }
  await load(name, "mesh");
  const frameDir = join(root, "preview", "frames", name);
  await mkdir(frameDir, { recursive: true });
  for (let frame = 0; frame < 90; frame++) {
    const orbit = frame * 4;
    await page.locator("model-viewer").evaluate((element, degrees) => {
      element.autoRotate = false;
      element.cameraOrbit = `${degrees}deg 75deg auto`;
      element.jumpCameraToGoal();
    }, orbit);
    await page.waitForTimeout(35);
    await page.locator("model-viewer").screenshot({ path: join(frameDir, `${String(frame).padStart(3, "0")}.png`) });
  }
  rendered.push(name);
}

await browser.close();
server.close();
await writeFile(join(root, "preview", "rendered.json"), JSON.stringify({ rendered }, null, 2) + "\n");
