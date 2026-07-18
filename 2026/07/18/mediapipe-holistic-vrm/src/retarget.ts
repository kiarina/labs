import type { Category, Landmark, NormalizedLandmark } from "@mediapipe/tasks-vision";
import type { VRM, VRMHumanBoneName } from "@pixiv/three-vrm";
import { Matrix4, Object3D, Quaternion, Vector3 } from "three";

export interface MotionFrame {
  pose: Landmark[];
  face: NormalizedLandmark[];
  leftHand: Landmark[];
  rightHand: Landmark[];
  blendshapes: Category[];
}

export interface RetargetOptions {
  mirror: boolean;
  smoothing: number;
}

interface BoneTarget {
  bone: VRMHumanBoneName;
  from: number;
  to: number;
  source: "pose" | "leftHand" | "rightHand";
}

const LIMBS: BoneTarget[] = [
  { bone: "leftUpperArm", from: 11, to: 13, source: "pose" },
  { bone: "leftLowerArm", from: 13, to: 15, source: "pose" },
  { bone: "rightUpperArm", from: 12, to: 14, source: "pose" },
  { bone: "rightLowerArm", from: 14, to: 16, source: "pose" },
  { bone: "leftUpperLeg", from: 23, to: 25, source: "pose" },
  { bone: "leftLowerLeg", from: 25, to: 27, source: "pose" },
  { bone: "leftFoot", from: 27, to: 31, source: "pose" },
  { bone: "rightUpperLeg", from: 24, to: 26, source: "pose" },
  { bone: "rightLowerLeg", from: 26, to: 28, source: "pose" },
  { bone: "rightFoot", from: 28, to: 32, source: "pose" },
];

interface FingerChain {
  bones: string[];
  indices: number[];
}

const FINGERS: FingerChain[] = [
  { bones: ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"], indices: [1, 2, 3, 4] },
  { bones: ["IndexProximal", "IndexIntermediate", "IndexDistal"], indices: [5, 6, 7, 8] },
  { bones: ["MiddleProximal", "MiddleIntermediate", "MiddleDistal"], indices: [9, 10, 11, 12] },
  { bones: ["RingProximal", "RingIntermediate", "RingDistal"], indices: [13, 14, 15, 16] },
  { bones: ["LittleProximal", "LittleIntermediate", "LittleDistal"], indices: [17, 18, 19, 20] },
];

const tmpFrom = new Vector3();
const tmpTo = new Vector3();
const tmpParentQ = new Quaternion();
export const LEG_VISIBILITY_THRESHOLD = 0.65;
export const TRACKING_LOSS_GRACE_MS = 500;
const NEUTRAL_RETURN_SMOOTHING = 0.8;
export const MAX_WRIST_ANGLE = 110 * Math.PI / 180;
export const BONE_DEAD_ZONE = 2 * Math.PI / 180;
export const FINGER_DEAD_ZONE = 3 * Math.PI / 180;
const LEG_BONES = new Set<VRMHumanBoneName>([
  "leftUpperLeg", "leftLowerLeg", "leftFoot",
  "rightUpperLeg", "rightLowerLeg", "rightFoot",
]);

export function landmarkVector(point: Pick<Landmark, "x" | "y" | "z">, mirror: boolean): Vector3 {
  return new Vector3(mirror ? point.x : -point.x, -point.y, -point.z);
}

export function quaternionBetween(from: Vector3, to: Vector3): Quaternion {
  if (from.lengthSq() < 1e-10 || to.lengthSq() < 1e-10) return new Quaternion();
  return new Quaternion().setFromUnitVectors(from.clone().normalize(), to.clone().normalize());
}

export function palmBasis(wrist: Vector3, indexMcp: Vector3, littleMcp: Vector3): Quaternion | null {
  const across = indexMcp.clone().sub(littleMcp);
  const forward = indexMcp.clone().add(littleMcp).multiplyScalar(0.5).sub(wrist);
  if (across.lengthSq() < 1e-8 || forward.lengthSq() < 1e-8) return null;
  across.normalize();
  const normal = across.clone().cross(forward).normalize();
  if (normal.lengthSq() < 1e-8) return null;
  forward.copy(normal).cross(across).normalize();
  return new Quaternion().setFromRotationMatrix(new Matrix4().makeBasis(across, forward, normal));
}

export function clampQuaternionAngle(rotation: Quaternion, maxAngle: number): Quaternion {
  const angle = rotation.angleTo(new Quaternion());
  if (angle <= maxAngle || angle < 1e-8) return rotation.clone();
  return new Quaternion().slerp(rotation, maxAngle / angle);
}

export function applyAngularDeadZone(previous: Quaternion | undefined, next: Quaternion, threshold: number): Quaternion {
  if (previous && previous.angleTo(next) < threshold) return previous.clone();
  return next.clone();
}

export function smoothFactor(smoothing: number, elapsedSeconds: number): number {
  const retention = Math.min(0.999, Math.max(0, smoothing));
  if (retention === 0) return 1;
  return 1 - Math.pow(retention, Math.max(0, elapsedSeconds) * 60);
}

export function isReliableLandmark(point: Landmark | undefined, threshold: number): boolean {
  if (!point) return false;
  return (point.visibility ?? 1) >= threshold;
}

export function categoryMap(categories: Category[]): Map<string, number> {
  return new Map(categories.map((category) => [category.categoryName, category.score]));
}

export class VrmRetargeter {
  private vrm: VRM | null = null;
  private restWorldQuaternions = new Map<VRMHumanBoneName, Quaternion>();
  private restDirections = new Map<VRMHumanBoneName, Vector3>();
  private restPalmBases = new Map<"left" | "right", Quaternion>();
  private targets = new Map<VRMHumanBoneName, Quaternion>();
  private stableTargets = new Map<VRMHumanBoneName, Quaternion>();
  private lastUpdate: number | null = null;
  private lastPoseAt: number | null = null;
  drivenBones = 0;

  setVrm(vrm: VRM): void {
    this.vrm = vrm;
    this.restWorldQuaternions.clear();
    this.restDirections.clear();
    this.restPalmBases.clear();
    this.targets.clear();
    this.stableTargets.clear();
    this.lastUpdate = null;
    this.lastPoseAt = null;
    vrm.scene.updateMatrixWorld(true);
    const names = [
      ...LIMBS.map((item) => item.bone),
      "leftHand", "rightHand", "hips", "spine", "chest", "neck", "head",
    ] as VRMHumanBoneName[];
    for (const name of names) this.captureRest(name);
    for (const side of ["left", "right"] as const) {
      for (const finger of FINGERS) {
        for (const bone of finger.bones) this.captureRest(`${side}${bone}` as VRMHumanBoneName);
      }
      this.capturePalmRest(side);
    }
    this.drivenBones = this.restDirections.size;
  }

  update(frame: MotionFrame | null, options: RetargetOptions, now = performance.now()): void {
    if (!this.vrm) return;
    const elapsed = this.lastUpdate === null ? 1 / 60 : Math.min(0.1, Math.max(0, (now - this.lastUpdate) / 1000));
    this.lastUpdate = now;
    this.vrm.scene.updateMatrixWorld(true);

    if (!frame || frame.pose.length < 33) {
      if (this.lastPoseAt !== null && now - this.lastPoseAt < TRACKING_LOSS_GRACE_MS) return;
      const neutralAlpha = smoothFactor(NEUTRAL_RETURN_SMOOTHING, elapsed);
      this.stableTargets.clear();
      this.setNeutralTargets();
      this.applyTargets(neutralAlpha);
      this.updateExpressions([], neutralAlpha);
      return;
    }

    this.lastPoseAt = now;
    const alpha = smoothFactor(options.smoothing, elapsed);
    this.setNeutralTargets();

    this.updateTorso(frame.pose, options.mirror);
    for (const target of LIMBS) {
      const points = target.source === "pose" ? frame.pose : target.source === "leftHand" ? frame.leftHand : frame.rightHand;
      const reliable = !LEG_BONES.has(target.bone)
        || (isReliableLandmark(points[target.from], LEG_VISIBILITY_THRESHOLD)
          && isReliableLandmark(points[target.to], LEG_VISIBILITY_THRESHOLD));
      if (points.length > target.to && reliable) this.aimBone(target.bone, points[target.from], points[target.to], options.mirror);
    }
    this.updateHand("left", frame.leftHand, options.mirror);
    this.updateHand("right", frame.rightHand, options.mirror);
    this.updateFingers("left", frame.leftHand, options.mirror);
    this.updateFingers("right", frame.rightHand, options.mirror);
    this.updateHead(frame.face, options.mirror);
    this.applyTargets(alpha);
    this.updateExpressions(frame.blendshapes, alpha);
  }

  reset(): void {
    if (!this.vrm) return;
    for (const name of this.restWorldQuaternions.keys()) {
      const node = this.vrm.humanoid.getNormalizedBoneNode(name);
      node?.quaternion.identity();
    }
    this.targets.clear();
    this.stableTargets.clear();
    this.lastUpdate = null;
    this.lastPoseAt = null;
  }

  private setNeutralTargets(): void {
    this.targets.clear();
    for (const name of this.restWorldQuaternions.keys()) this.targets.set(name, new Quaternion());
  }

  private setMotionTarget(name: VRMHumanBoneName, target: Quaternion, deadZone = BONE_DEAD_ZONE): void {
    const stable = applyAngularDeadZone(this.stableTargets.get(name), target, deadZone);
    this.stableTargets.set(name, stable);
    this.targets.set(name, stable);
  }

  private captureRest(name: VRMHumanBoneName): void {
    const node = this.vrm?.humanoid.getNormalizedBoneNode(name);
    if (!node) return;
    const child = this.findBoneChild(node);
    if (!child) return;
    const position = node.getWorldPosition(new Vector3());
    const childPosition = child.getWorldPosition(new Vector3());
    this.restWorldQuaternions.set(name, node.getWorldQuaternion(new Quaternion()));
    this.restDirections.set(name, childPosition.sub(position).normalize());
  }

  private findBoneChild(node: Object3D): Object3D | null {
    const queue = [...node.children];
    while (queue.length > 0) {
      const child = queue.shift()!;
      if (child.position.lengthSq() > 1e-10) return child;
      queue.push(...child.children);
    }
    return null;
  }

  private capturePalmRest(side: "left" | "right"): void {
    const hand = this.vrm?.humanoid.getNormalizedBoneNode(`${side}Hand` as VRMHumanBoneName);
    const index = this.vrm?.humanoid.getNormalizedBoneNode(`${side}IndexProximal` as VRMHumanBoneName);
    const little = this.vrm?.humanoid.getNormalizedBoneNode(`${side}LittleProximal` as VRMHumanBoneName);
    if (!hand || !index || !little) return;
    const basis = palmBasis(
      hand.getWorldPosition(new Vector3()),
      index.getWorldPosition(new Vector3()),
      little.getWorldPosition(new Vector3()),
    );
    if (basis) this.restPalmBases.set(side, basis);
  }

  private aimBone(
    name: VRMHumanBoneName,
    from: Landmark,
    to: Landmark,
    mirror: boolean,
    deadZone = BONE_DEAD_ZONE,
  ): void {
    const restDirection = this.restDirections.get(name);
    const restWorld = this.restWorldQuaternions.get(name);
    const node = this.vrm?.humanoid.getNormalizedBoneNode(name);
    if (!node || !restDirection || !restWorld) return;
    tmpFrom.copy(restDirection);
    tmpTo.copy(landmarkVector(to, mirror)).sub(landmarkVector(from, mirror));
    if (tmpTo.lengthSq() < 1e-8) return;
    const desiredWorld = quaternionBetween(tmpFrom, tmpTo).multiply(restWorld);
    const parentWorld = node.parent?.getWorldQuaternion(tmpParentQ) ?? tmpParentQ.identity();
    this.setMotionTarget(name, parentWorld.clone().invert().multiply(desiredWorld), deadZone);
  }

  private updateTorso(pose: Landmark[], mirror: boolean): void {
    if (![11, 12, 23, 24].every((index) => isReliableLandmark(pose[index], 0.5))) return;
    const leftHip = landmarkVector(pose[23], mirror);
    const rightHip = landmarkVector(pose[24], mirror);
    const leftShoulder = landmarkVector(pose[11], mirror);
    const rightShoulder = landmarkVector(pose[12], mirror);
    const hipCenter = leftHip.clone().add(rightHip).multiplyScalar(0.5);
    const shoulderCenter = leftShoulder.clone().add(rightShoulder).multiplyScalar(0.5);
    const xAxis = rightHip.clone().sub(leftHip).normalize();
    const yAxis = shoulderCenter.clone().sub(hipCenter).normalize();
    const zAxis = xAxis.clone().cross(yAxis).normalize();
    if (xAxis.lengthSq() === 0 || yAxis.lengthSq() === 0 || zAxis.lengthSq() === 0) return;
    yAxis.copy(zAxis).cross(xAxis).normalize();
    const basis = new Matrix4().makeBasis(xAxis, yAxis, zAxis);
    const torsoWorld = new Quaternion().setFromRotationMatrix(basis);
    for (const name of ["hips", "spine", "chest"] as VRMHumanBoneName[]) {
      const node = this.vrm?.humanoid.getNormalizedBoneNode(name);
      if (!node) continue;
      const parentWorld = node.parent?.getWorldQuaternion(new Quaternion()) ?? new Quaternion();
      const weight = name === "hips" ? 0.55 : name === "spine" ? 0.25 : 0.2;
      const distributed = new Quaternion().slerp(torsoWorld, weight);
      this.setMotionTarget(name, parentWorld.invert().multiply(distributed));
    }
  }

  private updateHead(face: NormalizedLandmark[], mirror: boolean): void {
    if (face.length <= 454 || !this.vrm) return;
    const left = landmarkVector(face[234], mirror);
    const right = landmarkVector(face[454], mirror);
    const forehead = landmarkVector(face[10], mirror);
    const chin = landmarkVector(face[152], mirror);
    const xAxis = right.sub(left).normalize();
    const yAxis = forehead.sub(chin).normalize();
    const zAxis = xAxis.clone().cross(yAxis).normalize();
    yAxis.copy(zAxis).cross(xAxis).normalize();
    if (zAxis.lengthSq() < 1e-8) return;
    const headWorld = new Quaternion().setFromRotationMatrix(new Matrix4().makeBasis(xAxis, yAxis, zAxis));
    for (const [name, weight] of [["neck", 0.35], ["head", 0.65]] as Array<[VRMHumanBoneName, number]>) {
      const node = this.vrm.humanoid.getNormalizedBoneNode(name);
      if (!node) continue;
      const parentWorld = node.parent?.getWorldQuaternion(new Quaternion()) ?? new Quaternion();
      this.setMotionTarget(name, parentWorld.invert().multiply(new Quaternion().slerp(headWorld, weight)));
    }
  }

  private updateHand(side: "left" | "right", points: Landmark[], mirror: boolean): void {
    if (points.length < 18 || !this.vrm) return;
    const name = `${side}Hand` as VRMHumanBoneName;
    const node = this.vrm.humanoid.getNormalizedBoneNode(name);
    const restWorld = this.restWorldQuaternions.get(name);
    const restBasis = this.restPalmBases.get(side);
    if (!node || !restWorld || !restBasis) return;
    const observedBasis = palmBasis(
      landmarkVector(points[0], mirror),
      landmarkVector(points[5], mirror),
      landmarkVector(points[17], mirror),
    );
    if (!observedBasis) return;
    const desiredWorld = observedBasis.multiply(restBasis.clone().invert()).multiply(restWorld);
    const parentWorld = node.parent?.getWorldQuaternion(new Quaternion()) ?? new Quaternion();
    const desiredLocal = parentWorld.invert().multiply(desiredWorld);
    this.setMotionTarget(name, clampQuaternionAngle(desiredLocal, MAX_WRIST_ANGLE), FINGER_DEAD_ZONE);
  }

  private updateFingers(side: "left" | "right", points: Landmark[], mirror: boolean): void {
    if (points.length < 21) return;
    for (const finger of FINGERS) {
      for (let i = 0; i < finger.bones.length; i++) {
        this.aimBone(
          `${side}${finger.bones[i]}` as VRMHumanBoneName,
          points[finger.indices[i]],
          points[finger.indices[i + 1]],
          mirror,
          FINGER_DEAD_ZONE,
        );
      }
    }
  }

  private applyTargets(alpha: number): void {
    if (!this.vrm) return;
    for (const [name, target] of this.targets) {
      const node = this.vrm.humanoid.getNormalizedBoneNode(name);
      node?.quaternion.slerp(target, alpha);
    }
  }

  private updateExpressions(categories: Category[], alpha: number): void {
    const manager = this.vrm?.expressionManager;
    if (!manager) return;
    const values = categoryMap(categories);
    const get = (name: string): number => values.get(name) ?? 0;
    const average = (left: string, right: string): number => (get(left) + get(right)) / 2;
    const targets: Record<string, number> = {
      blinkLeft: get("eyeBlinkLeft"),
      blinkRight: get("eyeBlinkRight"),
      aa: get("jawOpen"),
      ih: Math.max(average("mouthSmileLeft", "mouthSmileRight") * 0.35, average("mouthStretchLeft", "mouthStretchRight")),
      ou: get("mouthPucker"),
      ee: average("mouthStretchLeft", "mouthStretchRight"),
      oh: get("mouthFunnel"),
      happy: average("mouthSmileLeft", "mouthSmileRight") * 0.7,
      surprised: Math.max(average("eyeWideLeft", "eyeWideRight"), get("jawOpen")) * 0.35,
    };
    for (const [name, target] of Object.entries(targets)) {
      const current = manager.getValue(name) ?? 0;
      manager.setValue(name, current + (target - current) * alpha);
    }
  }
}
