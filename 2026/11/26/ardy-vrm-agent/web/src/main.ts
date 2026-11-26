// Bridge between the Flutter app and the ARDY Mini inference worker.
//
// The page has no UI. Flutter sends commands with
// `window.ardyBridge.command(json)` and receives events on the
// `ArdyHost` JavaScript channel. Generated chunks are retargeted to VRM
// normalized bone rotations here (with ARDY Mini's own retargeting code), so
// Flutter only has to copy quaternions into flutter_vrm.

import {
  createVrmRetargetPlan,
  retargetMotionFrame,
  type VrmRetargetPlan,
} from "./ardy/vrm-retarget";
import {
  normalizeSkeletonMetadata,
  normalizeStructuredMotion,
} from "./ardy/motion-data";
import type {
  BrowserModelManifest,
  GenerationMode,
  RuntimeGenerationChunk,
  WorkerEvent,
} from "./ardy/runtime";

/** Model family root at an immutable Hugging Face commit. */
const MODEL_BASE_URL =
  "https://huggingface.co/intsuc/Llama-3-ARDY-Mini-Core40-Browser/resolve/1c21362effeecec0454bfc0d818661525ae6b387/";

declare global {
  interface Window {
    ArdyHost?: { postMessage(message: string): void };
    ardyBridge: { command(json: string): string };
  }
}

type Command =
  | { type: "load"; presentBones: string[]; hipsHeight: number }
  | {
      type: "generate";
      mode: GenerationMode;
      prompt: string;
      seed?: number;
      durationFrames?: number;
      branchFrame?: number;
    }
  | { type: "cancel" };

function send(event: Record<string, unknown>): void {
  const text = JSON.stringify(event);
  if (window.ArdyHost) window.ArdyHost.postMessage(text);
  else console.log("[ardy]", text);
}

const worker = new Worker(new URL("./ardy/inference.worker.ts", import.meta.url), {
  type: "module",
});

let requestCounter = 0;
const nextId = (prefix: string) => `${prefix}-${++requestCounter}`;

let manifest: BrowserModelManifest | null = null;
let plan: VrmRetargetPlan | null = null;
let pendingLoad: { presentBones: string[]; hipsHeight: number } | null = null;
let loadStartedAt = 0;
let activeGeneration: { id: string; mode: GenerationMode; startedAt: number } | null =
  null;

function round(value: number): number {
  return Math.round(value * 1e5) / 1e5;
}

function emitChunk(chunk: RuntimeGenerationChunk, mode: GenerationMode): void {
  if (!manifest || !plan) return;
  const motion = normalizeStructuredMotion(
    {
      positions: chunk.joints,
      frameCount: chunk.frameCount,
      fps: chunk.fps,
      localRotations: chunk.localRotations,
      localRotationFormat: chunk.localRotations ? "matrix3x3-row-major" : undefined,
      globalRotations: chunk.globalRotations,
      globalRotationFormat: chunk.globalRotations ? "matrix3x3-row-major" : undefined,
      roots: chunk.rootPositions,
      contacts: chunk.footContacts,
    },
    { skeleton: manifest.skeleton, defaultFps: chunk.fps },
  );
  const bones = plan.bindings.map((binding) => binding.targetBone);
  // Per frame: hips xyz, then xyzw for each bone in `bones` order.
  const frames: number[][] = [];
  for (let frame = 0; frame < motion.frameCount; frame += 1) {
    const pose = retargetMotionFrame(motion, frame, plan);
    const values = pose.hipsPosition.map(round);
    for (const rotation of pose.rotations) values.push(...rotation.rotation.map(round));
    frames.push(values);
  }
  send({
    type: "frames",
    mode,
    startFrame: chunk.startFrame,
    fps: chunk.fps,
    prompt: chunk.prompt,
    bones,
    frames,
    timingsMs: chunk.timingsMs,
  });
}

worker.addEventListener("message", (message: MessageEvent<WorkerEvent>) => {
  try {
    onWorkerEvent(message.data);
  } catch (error) {
    send({ type: "error", error: { name: "BridgeError", message: String(error) } });
  }
});

function onWorkerEvent(event: WorkerEvent): void {
  switch (event.type) {
    case "workerReady":
      send({ type: "workerReady", protocolVersion: event.protocolVersion });
      break;
    case "webGpuCapabilities": {
      const variant = event.shaderF16 ? "fp16" : "fp32";
      send({ type: "webGpu", shaderF16: event.shaderF16, variant });
      loadStartedAt = performance.now();
      worker.postMessage({
        type: "loadModel",
        requestId: nextId("load"),
        baseUrl: `${MODEL_BASE_URL}${variant}/`,
      });
      break;
    }
    case "progress":
      send({
        type: "progress",
        stage: event.stage,
        completed: event.completed,
        total: event.total,
        message: event.message,
      });
      break;
    case "modelLoaded": {
      manifest = event.model.manifest;
      const load = pendingLoad!;
      plan = createVrmRetargetPlan(normalizeSkeletonMetadata(manifest.skeleton), {
        presentBones: load.presentBones as never,
        targetHipsHeight: load.hipsHeight,
        metaVersion: "1",
      });
      send({
        type: "loaded",
        modelId: event.model.id,
        variant: event.model.variant,
        revision: event.model.revision,
        fps: event.model.fps,
        generationFrames: event.model.generationFrames,
        loadMs: Math.round(performance.now() - loadStartedAt),
        bones: plan.bindings.map((binding) => binding.targetBone),
      });
      break;
    }
    case "generationChunk":
      emitChunk(event.chunk, event.mode);
      break;
    case "generationComplete":
      send({
        type: "complete",
        mode: event.mode,
        generatedFrameCount: event.generatedFrameCount,
        sessionFrameCount: event.sessionFrameCount,
        wallMs: activeGeneration
          ? Math.round(performance.now() - activeGeneration.startedAt)
          : null,
        timingsMs: event.result.timingsMs,
      });
      activeGeneration = null;
      break;
    case "cancelled":
      send({ type: "cancelled" });
      activeGeneration = null;
      break;
    case "error":
      send({ type: "error", requestId: event.requestId, error: event.error });
      if (activeGeneration?.id === event.requestId) activeGeneration = null;
      break;
    default:
      break;
  }
}

worker.addEventListener("error", (event) => {
  send({ type: "error", error: { name: "WorkerError", message: event.message } });
});

function run(command: Command): unknown {
  switch (command.type) {
    case "load":
      pendingLoad = { presentBones: command.presentBones, hipsHeight: command.hipsHeight };
      worker.postMessage({ type: "getWebGpuCapabilities", requestId: nextId("caps") });
      return { ok: true };
    case "generate": {
      if (activeGeneration) return { ok: false, reason: "busy" };
      const id = nextId("gen");
      activeGeneration = { id, mode: command.mode, startedAt: performance.now() };
      worker.postMessage({
        type: "generate",
        requestId: id,
        mode: command.mode,
        prompt: command.prompt,
        seed: command.seed ?? 0,
        durationFrames: command.durationFrames ?? 40,
        ...(command.mode === "branch" ? { branchFrame: command.branchFrame ?? 0 } : {}),
      });
      return { ok: true, requestId: id };
    }
    case "cancel":
      if (activeGeneration) {
        worker.postMessage({
          type: "cancel",
          requestId: nextId("cancel"),
          targetRequestId: activeGeneration.id,
        });
      }
      return { ok: true };
  }
}

window.addEventListener("error", (event) => {
  send({ type: "error", error: { name: "PageError", message: String(event.message) } });
});
window.addEventListener("unhandledrejection", (event) => {
  send({ type: "error", error: { name: "PageRejection", message: String(event.reason) } });
});

window.ardyBridge = {
  command(json: string): string {
    try {
      return JSON.stringify(run(JSON.parse(json) as Command));
    } catch (error) {
      return JSON.stringify({ ok: false, reason: String(error) });
    }
  },
};

send({
  type: "page",
  webgpu: "gpu" in navigator,
  secure: window.isSecureContext,
  userAgent: navigator.userAgent,
});
