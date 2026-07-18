import "./style.css";
import {
  DrawingUtils,
  FilesetResolver,
  HolisticLandmarker,
  type HolisticLandmarkerResult,
} from "@mediapipe/tasks-vision";
import {
  VRMLoaderPlugin,
  VRMUtils,
  type VRM,
} from "@pixiv/three-vrm";
import {
  Box3,
  Color,
  DirectionalLight,
  GridHelper,
  HemisphereLight,
  PerspectiveCamera,
  Scene,
  Vector3,
  WebGLRenderer,
} from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { VrmRetargeter, type MotionFrame } from "./retarget";

const $ = <T extends HTMLElement>(selector: string): T => {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`Missing element: ${selector}`);
  return element;
};

const cameraVideo = $("#camera") as HTMLVideoElement;
const overlay = $("#overlay") as HTMLCanvasElement;
const avatarCanvas = $("#avatar") as HTMLCanvasElement;
const avatarStage = $("#avatar-stage");
const cameraStage = $(".camera-stage");
const status = $("#status");
const cameraToggle = $("#camera-toggle") as HTMLButtonElement;
const vrmFile = $("#vrm-file") as HTMLInputElement;
const smoothing = $("#smoothing") as HTMLInputElement;
const smoothValue = $("#smooth-value") as HTMLOutputElement;
const mirror = $("#mirror") as HTMLInputElement;
const showCamera = $("#show-camera") as HTMLInputElement;
const showLandmarks = $("#show-landmarks") as HTMLInputElement;
const latency = $("#latency");
const inferenceFps = $("#inference-fps");
const renderFps = $("#render-fps");
const avatarName = $("#avatar-name");
const boneCount = $("#bone-count");
const cameraPlaceholder = $("#camera-placeholder");

const trackingElements = {
  pose: $("#track-pose"),
  face: $("#track-face"),
  leftHand: $("#track-left-hand"),
  rightHand: $("#track-right-hand"),
};

const scene = new Scene();
scene.background = new Color(0x090d14);
const renderCamera = new PerspectiveCamera(30, 1, 0.1, 100);
renderCamera.position.set(0, 1.35, 3.2);
const renderer = new WebGLRenderer({ canvas: avatarCanvas, antialias: true, alpha: false });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.outputColorSpace = "srgb";
renderer.shadowMap.enabled = true;

const controls = new OrbitControls(renderCamera, avatarCanvas);
controls.target.set(0, 1, 0);
controls.enableDamping = true;
controls.minDistance = 1.5;
controls.maxDistance = 7;

scene.add(new HemisphereLight(0xc8e7ff, 0x182035, 2.5));
const keyLight = new DirectionalLight(0xffffff, 3.2);
keyLight.position.set(1.8, 3.5, 2.8);
keyLight.castShadow = true;
scene.add(keyLight);
const grid = new GridHelper(10, 40, 0x26364c, 0x162131);
grid.position.y = 0;
scene.add(grid);

const loader = new GLTFLoader();
loader.register((parser) => new VRMLoaderPlugin(parser));
const retargeter = new VrmRetargeter();
let currentVrm: VRM | null = null;
let landmarker: HolisticLandmarker | null = null;
let mediaStream: MediaStream | null = null;
let lastVideoTime = -1;
let inferenceTimes: number[] = [];
let inferenceDurations: number[] = [];
let retargetFrames = 0;
const detectedFrames = { total: 0, pose: 0, face: 0, leftHand: 0, rightHand: 0 };
let renderFrames = 0;
let renderWindowStart = performance.now();

function setStatus(text: string, state: "loading" | "ready" | "error"): void {
  status.dataset.state = state;
  status.querySelector("span")!.textContent = text;
}

function resizeRenderer(): void {
  const width = avatarStage.clientWidth;
  const height = avatarStage.clientHeight;
  renderer.setSize(width, height, false);
  renderCamera.aspect = width / Math.max(height, 1);
  renderCamera.updateProjectionMatrix();
}

function frameVrm(vrm: VRM): void {
  const bounds = new Box3().setFromObject(vrm.scene);
  const size = bounds.getSize(new Vector3());
  const center = bounds.getCenter(new Vector3());
  const height = Math.max(size.y, 1);
  controls.target.set(center.x, center.y + height * 0.03, center.z);
  renderCamera.position.set(center.x, center.y + height * 0.04, center.z + height * 1.45);
  renderCamera.near = height / 100;
  renderCamera.far = height * 20;
  renderCamera.updateProjectionMatrix();
  controls.update();
}

async function loadVrm(source: string, label: string): Promise<void> {
  setStatus("VRMを読み込み中", "loading");
  const gltf = await loader.loadAsync(source);
  const vrm = gltf.userData.vrm as VRM | undefined;
  if (!vrm) throw new Error("The selected file is not a VRM model");
  if (currentVrm) scene.remove(currentVrm.scene);
  VRMUtils.removeUnnecessaryVertices(gltf.scene);
  VRMUtils.combineSkeletons(gltf.scene);
  VRMUtils.combineMorphs(vrm);
  VRMUtils.rotateVRM0(vrm);
  currentVrm = vrm;
  scene.add(vrm.scene);
  vrm.scene.traverse((object) => {
    object.frustumCulled = false;
  });
  retargeter.setVrm(vrm);
  frameVrm(vrm);
  avatarName.textContent = label;
  boneCount.textContent = `${retargeter.drivenBones} bones driven`;
  if (landmarker) {
    cameraToggle.disabled = false;
    setStatus("READY / カメラ待機", "ready");
  }
}

async function createLandmarker(): Promise<void> {
  const vision = await FilesetResolver.forVisionTasks("/wasm");
  landmarker = await HolisticLandmarker.createFromOptions(vision, {
    baseOptions: { modelAssetPath: "/models/holistic_landmarker.task" },
    runningMode: "VIDEO",
    outputFaceBlendshapes: true,
    outputPoseSegmentationMasks: false,
    minFaceDetectionConfidence: 0.5,
    minFacePresenceConfidence: 0.5,
    minPoseDetectionConfidence: 0.5,
    minPosePresenceConfidence: 0.5,
    minHandLandmarksConfidence: 0.5,
  });
  if (currentVrm) {
    cameraToggle.disabled = false;
    setStatus("READY / カメラ待機", "ready");
  }
}

function setTracking(result: HolisticLandmarkerResult): void {
  trackingElements.pose.classList.toggle("active", result.poseWorldLandmarks.length > 0);
  trackingElements.face.classList.toggle("active", result.faceLandmarks.length > 0);
  trackingElements.leftHand.classList.toggle("active", result.leftHandWorldLandmarks.length > 0);
  trackingElements.rightHand.classList.toggle("active", result.rightHandWorldLandmarks.length > 0);
}

function drawLandmarks(result: HolisticLandmarkerResult): void {
  const width = cameraVideo.videoWidth;
  const height = cameraVideo.videoHeight;
  if (!width || !height) return;
  if (overlay.width !== width || overlay.height !== height) {
    overlay.width = width;
    overlay.height = height;
  }
  const context = overlay.getContext("2d")!;
  context.clearRect(0, 0, width, height);
  if (!showLandmarks.checked) return;
  context.save();
  if (mirror.checked) {
    context.translate(width, 0);
    context.scale(-1, 1);
  }
  const drawing = new DrawingUtils(context);
  const pose = result.poseLandmarks[0];
  const face = result.faceLandmarks[0];
  const leftHand = result.leftHandLandmarks[0];
  const rightHand = result.rightHandLandmarks[0];
  if (pose) {
    drawing.drawConnectors(pose, HolisticLandmarker.POSE_CONNECTIONS, { color: "#62e8d3", lineWidth: 2 });
    drawing.drawLandmarks(pose, { color: "#e9edf4", radius: 2 });
  }
  if (face) {
    drawing.drawConnectors(face, HolisticLandmarker.FACE_LANDMARKS_CONTOURS, { color: "#6fa7ff99", lineWidth: 1 });
  }
  for (const hand of [leftHand, rightHand]) {
    if (!hand) continue;
    drawing.drawConnectors(hand, HolisticLandmarker.HAND_CONNECTIONS, { color: "#6fa7ff", lineWidth: 2 });
    drawing.drawLandmarks(hand, { color: "#e9edf4", radius: 2 });
  }
  context.restore();
}

function processResult(result: HolisticLandmarkerResult): void {
  detectedFrames.total++;
  if (result.poseWorldLandmarks.length > 0) detectedFrames.pose++;
  if (result.faceLandmarks.length > 0) detectedFrames.face++;
  if (result.leftHandWorldLandmarks.length > 0) detectedFrames.leftHand++;
  if (result.rightHandWorldLandmarks.length > 0) detectedFrames.rightHand++;
  for (const [name, value] of Object.entries(detectedFrames)) boneCount.dataset[name] = value.toString();
  setTracking(result);
  drawLandmarks(result);
  const pose = result.poseWorldLandmarks[0];
  const options = {
    mirror: mirror.checked,
    smoothing: Number(smoothing.value),
  };
  if (pose) {
    const frame: MotionFrame = {
      pose,
      face: result.faceLandmarks[0] ?? [],
      leftHand: result.leftHandWorldLandmarks[0] ?? [],
      rightHand: result.rightHandWorldLandmarks[0] ?? [],
      blendshapes: result.faceBlendshapes[0]?.categories ?? [],
    };
    retargeter.update(frame, options);
    retargetFrames++;
    boneCount.dataset.retargetFrames = retargetFrames.toString();
  } else {
    retargeter.update(null, options);
  }
}

function updateInferenceFps(now: number): void {
  inferenceTimes.push(now);
  inferenceTimes = inferenceTimes.filter((time) => now - time <= 1000);
  inferenceFps.textContent = inferenceTimes.length.toFixed(1);
}

function inferenceLoop(): void {
  if (mediaStream && landmarker && cameraVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA && cameraVideo.currentTime !== lastVideoTime) {
    lastVideoTime = cameraVideo.currentTime;
    const started = performance.now();
    landmarker.detectForVideo(cameraVideo, started, processResult);
    const finished = performance.now();
    const duration = finished - started;
    latency.textContent = duration.toFixed(0);
    inferenceDurations.push(duration);
    inferenceDurations = inferenceDurations.slice(-300);
    const sorted = [...inferenceDurations].sort((a, b) => a - b);
    latency.dataset.samples = sorted.length.toString();
    latency.dataset.mean = (sorted.reduce((sum, value) => sum + value, 0) / sorted.length).toFixed(2);
    latency.dataset.p50 = sorted[Math.floor((sorted.length - 1) * 0.5)].toFixed(2);
    latency.dataset.p95 = sorted[Math.floor((sorted.length - 1) * 0.95)].toFixed(2);
    updateInferenceFps(finished);
  }
  requestAnimationFrame(inferenceLoop);
}

async function startCamera(): Promise<void> {
  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: "user" },
  });
  cameraVideo.srcObject = mediaStream;
  await cameraVideo.play();
  cameraPlaceholder.classList.add("hidden");
  cameraToggle.textContent = "カメラを停止";
  setStatus("TRACKING", "ready");
}

function stopCamera(): void {
  mediaStream?.getTracks().forEach((track) => track.stop());
  mediaStream = null;
  cameraVideo.srcObject = null;
  cameraToggle.textContent = "カメラを開始";
  cameraPlaceholder.classList.remove("hidden");
  overlay.getContext("2d")?.clearRect(0, 0, overlay.width, overlay.height);
  Object.values(trackingElements).forEach((element) => element.classList.remove("active"));
  retargeter.reset();
  setStatus("READY / カメラ待機", "ready");
}

async function useVrmFile(file: File): Promise<void> {
  const url = URL.createObjectURL(file);
  try {
    await loadVrm(url, file.name);
  } finally {
    URL.revokeObjectURL(url);
  }
}

cameraToggle.addEventListener("click", async () => {
  cameraToggle.disabled = true;
  try {
    if (mediaStream) stopCamera();
    else await startCamera();
  } catch (error) {
    console.error(error);
    setStatus("カメラを開始できません", "error");
  } finally {
    cameraToggle.disabled = false;
  }
});

vrmFile.addEventListener("change", async () => {
  const file = vrmFile.files?.[0];
  if (file) await useVrmFile(file);
});

for (const eventName of ["dragenter", "dragover"]) {
  avatarStage.addEventListener(eventName, (event) => {
    event.preventDefault();
    avatarStage.classList.add("dragging");
  });
}
for (const eventName of ["dragleave", "drop"]) {
  avatarStage.addEventListener(eventName, (event) => {
    event.preventDefault();
    avatarStage.classList.remove("dragging");
  });
}
avatarStage.addEventListener("drop", async (event) => {
  const file = event.dataTransfer?.files[0];
  if (file) await useVrmFile(file);
});

smoothing.addEventListener("input", () => {
  smoothValue.value = Number(smoothing.value).toFixed(2);
});
mirror.addEventListener("change", () => {
  cameraStage.classList.toggle("mirrored", mirror.checked);
});
showCamera.addEventListener("change", () => {
  cameraStage.classList.toggle("feed-hidden", !showCamera.checked);
});
showLandmarks.addEventListener("change", () => {
  if (!showLandmarks.checked) overlay.getContext("2d")?.clearRect(0, 0, overlay.width, overlay.height);
});
cameraStage.classList.toggle("mirrored", mirror.checked);
cameraStage.classList.toggle("feed-hidden", !showCamera.checked);
window.addEventListener("resize", resizeRenderer);

let lastRenderTime = performance.now();
function render(): void {
  const now = performance.now();
  const delta = Math.min((now - lastRenderTime) / 1000, 0.1);
  lastRenderTime = now;
  currentVrm?.update(delta);
  controls.update();
  renderer.render(scene, renderCamera);
  renderFrames++;
  if (now - renderWindowStart >= 1000) {
    renderFps.textContent = Math.round((renderFrames * 1000) / (now - renderWindowStart)).toString();
    renderFrames = 0;
    renderWindowStart = now;
  }
  requestAnimationFrame(render);
}

resizeRenderer();
render();
inferenceLoop();

Promise.all([
  createLandmarker(),
  loadVrm("/models/Seed-san.vrm", "Seed-san / VRM 1.0"),
]).catch((error: unknown) => {
  console.error(error);
  setStatus("初期化に失敗しました", "error");
});

window.addEventListener("beforeunload", () => {
  stopCamera();
  landmarker?.close();
  renderer.dispose();
});
