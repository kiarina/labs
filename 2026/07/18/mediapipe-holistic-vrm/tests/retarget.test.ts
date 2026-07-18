import { describe, expect, it } from "vitest";
import type { Landmark } from "@mediapipe/tasks-vision";
import type { VRM } from "@pixiv/three-vrm";
import { Object3D, Quaternion, Vector3 } from "three";
import {
  BONE_DEAD_ZONE,
  LEG_VISIBILITY_THRESHOLD,
  MAX_WRIST_ANGLE,
  TRACKING_LOSS_GRACE_MS,
  VrmRetargeter,
  applyAngularDeadZone,
  categoryMap,
  clampQuaternionAngle,
  isReliableLandmark,
  landmarkVector,
  palmBasis,
  quaternionBetween,
  smoothFactor,
} from "../src/retarget";

describe("retarget math", () => {
  it("converts MediaPipe world coordinates and mirror mode", () => {
    expect(landmarkVector({ x: 1, y: 2, z: 3 }, true).toArray()).toEqual([1, -2, -3]);
    expect(landmarkVector({ x: 1, y: 2, z: 3 }, false).toArray()).toEqual([-1, -2, -3]);
  });

  it("rotates one normalized direction onto another", () => {
    const result = new Vector3(1, 0, 0).applyQuaternion(quaternionBetween(new Vector3(1, 0, 0), new Vector3(0, 1, 0)));
    expect(result.distanceTo(new Vector3(0, 1, 0))).toBeLessThan(1e-6);
  });

  it("recovers a full palm rotation from three landmarks", () => {
    const wrist = new Vector3(0, 0, 0);
    const index = new Vector3(1, 1, 0);
    const little = new Vector3(-1, 1, 0);
    const rotation = new Quaternion().setFromAxisAngle(new Vector3(1, 0, 0), Math.PI / 2);
    const rest = palmBasis(wrist, index, little)!;
    const observed = palmBasis(
      wrist.clone().applyQuaternion(rotation),
      index.clone().applyQuaternion(rotation),
      little.clone().applyQuaternion(rotation),
    )!;
    const recovered = observed.multiply(rest.invert());
    expect(recovered.angleTo(rotation)).toBeLessThan(1e-6);
  });

  it("limits excessive wrist rotation", () => {
    const rotation = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), Math.PI);
    expect(clampQuaternionAngle(rotation, MAX_WRIST_ANGLE).angleTo(new Quaternion())).toBeCloseTo(MAX_WRIST_ANGLE);
  });

  it("ignores sub-threshold angular landmark jitter", () => {
    const previous = new Quaternion();
    const tinyMotion = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), BONE_DEAD_ZONE * 0.5);
    const deliberateMotion = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), BONE_DEAD_ZONE * 2);
    expect(applyAngularDeadZone(previous, tinyMotion, BONE_DEAD_ZONE).angleTo(previous)).toBe(0);
    expect(applyAngularDeadZone(previous, deliberateMotion, BONE_DEAD_ZONE).angleTo(deliberateMotion)).toBe(0);
  });

  it("drives the hand from the observed palm plane", () => {
    const scene = new Object3D();
    const hand = new Object3D();
    const index = new Object3D();
    const little = new Object3D();
    index.position.set(1, 1, 0);
    little.position.set(-1, 1, 0);
    hand.add(index, little);
    scene.add(hand);
    const fakeVrm = {
      scene,
      humanoid: {
        getNormalizedBoneNode: (name: string) => ({
          leftHand: hand,
          leftIndexProximal: index,
          leftLittleProximal: little,
        })[name] ?? null,
      },
    } as unknown as VRM;
    const pose = Array.from({ length: 33 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 })) satisfies Landmark[];
    const leftHand = Array.from({ length: 21 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 })) satisfies Landmark[];
    leftHand[5] = { x: 1, y: 0, z: -1, visibility: 1 };
    leftHand[17] = { x: -1, y: 0, z: -1, visibility: 1 };
    const retargeter = new VrmRetargeter();
    retargeter.setVrm(fakeVrm);
    retargeter.update({ pose, face: [], leftHand, rightHand: [], blendshapes: [] }, { mirror: true, smoothing: 0 }, 0);
    const expected = new Quaternion().setFromAxisAngle(new Vector3(1, 0, 0), Math.PI / 2);
    expect(hand.quaternion.angleTo(expected)).toBeLessThan(1e-6);
  });

  it("drives all three VRM 1.0 thumb bones", () => {
    const scene = new Object3D();
    const hand = new Object3D();
    const index = new Object3D();
    const little = new Object3D();
    const metacarpal = new Object3D();
    const proximal = new Object3D();
    const distal = new Object3D();
    const tip = new Object3D();
    index.position.set(1, 1, 0);
    little.position.set(-1, 1, 0);
    metacarpal.position.set(0.2, 0.2, 0);
    proximal.position.set(0.4, 0, 0);
    distal.position.set(0.4, 0, 0);
    tip.position.set(0.4, 0, 0);
    distal.add(tip);
    proximal.add(distal);
    metacarpal.add(proximal);
    hand.add(index, little, metacarpal);
    scene.add(hand);
    const bones: Record<string, Object3D> = {
      leftHand: hand,
      leftIndexProximal: index,
      leftLittleProximal: little,
      leftThumbMetacarpal: metacarpal,
      leftThumbProximal: proximal,
      leftThumbDistal: distal,
    };
    const fakeVrm = {
      scene,
      humanoid: { getNormalizedBoneNode: (name: string) => bones[name] ?? null },
    } as unknown as VRM;
    const pose = Array.from({ length: 33 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 })) satisfies Landmark[];
    const leftHand = Array.from({ length: 21 }, () => ({ x: 0, y: 0, z: 0, visibility: 1 })) satisfies Landmark[];
    leftHand[5] = { x: 1, y: -1, z: 0, visibility: 1 };
    leftHand[17] = { x: -1, y: -1, z: 0, visibility: 1 };
    for (let i = 1; i <= 4; i++) leftHand[i] = { x: 0, y: -i, z: 0, visibility: 1 };
    const retargeter = new VrmRetargeter();
    retargeter.setVrm(fakeVrm);
    retargeter.update({ pose, face: [], leftHand, rightHand: [], blendshapes: [] }, { mirror: true, smoothing: 0 }, 0);
    for (const bone of [metacarpal, proximal, distal]) {
      expect(bone.quaternion.angleTo(new Quaternion())).toBeGreaterThan(1);
    }
  });

  it("returns identity for a degenerate direction", () => {
    expect(quaternionBetween(new Vector3(), new Vector3(1, 0, 0)).angleTo(new Quaternion())).toBe(0);
  });

  it("normalizes smoothing to elapsed time", () => {
    expect(smoothFactor(0, 1 / 60)).toBe(1);
    expect(smoothFactor(0.5, 1 / 60)).toBeCloseTo(0.5);
    expect(smoothFactor(0.5, 2 / 60)).toBeCloseTo(0.75);
  });

  it("indexes blendshape scores by category name", () => {
    const values = categoryMap([{ categoryName: "jawOpen", score: 0.8, index: 1, displayName: "" }]);
    expect(values.get("jawOpen")).toBe(0.8);
  });

  it("rejects landmarks below the configured confidence", () => {
    expect(isReliableLandmark({ x: 0, y: 0, z: 0, visibility: LEG_VISIBILITY_THRESHOLD }, LEG_VISIBILITY_THRESHOLD)).toBe(true);
    expect(isReliableLandmark({ x: 0, y: 0, z: 0, visibility: 0.2 }, LEG_VISIBILITY_THRESHOLD)).toBe(false);
  });

  it("returns an unreliable leg to neutral", () => {
    const scene = new Object3D();
    const upperLeg = new Object3D();
    const lowerLeg = new Object3D();
    lowerLeg.position.set(0, -1, 0);
    upperLeg.add(lowerLeg);
    scene.add(upperLeg);
    const fakeVrm = {
      scene,
      humanoid: { getNormalizedBoneNode: (name: string) => name === "leftUpperLeg" ? upperLeg : null },
    } as unknown as VRM;
    const pose = Array.from({ length: 33 }, () => ({ x: 0, y: 0, z: 0, visibility: 1, presence: 1 })) satisfies Landmark[];
    pose[23] = { x: 0, y: 0, z: 0, visibility: 1, presence: 1 };
    pose[25] = { x: 1, y: 0, z: 0, visibility: 1, presence: 1 };
    const retargeter = new VrmRetargeter();
    retargeter.setVrm(fakeVrm);
    const frame = { pose, face: [], leftHand: [], rightHand: [], blendshapes: [] };
    retargeter.update(frame, { mirror: true, smoothing: 0 }, 0);
    expect(upperLeg.quaternion.angleTo(new Quaternion())).toBeGreaterThan(1);
    pose[25].visibility = 0.2;
    retargeter.update(frame, { mirror: true, smoothing: 0 }, 16);
    expect(upperLeg.quaternion.angleTo(new Quaternion())).toBeLessThan(1e-6);
  });

  it("holds brief tracking gaps, then starts returning to neutral", () => {
    const scene = new Object3D();
    const upperArm = new Object3D();
    const lowerArm = new Object3D();
    lowerArm.position.set(1, 0, 0);
    upperArm.add(lowerArm);
    scene.add(upperArm);
    const fakeVrm = {
      scene,
      humanoid: { getNormalizedBoneNode: (name: string) => name === "leftUpperArm" ? upperArm : null },
    } as unknown as VRM;
    const pose = Array.from({ length: 33 }, () => ({ x: 0, y: 0, z: 0, visibility: 1, presence: 1 })) satisfies Landmark[];
    pose[13] = { x: 0, y: 1, z: 0, visibility: 1, presence: 1 };
    const retargeter = new VrmRetargeter();
    retargeter.setVrm(fakeVrm);
    retargeter.update({ pose, face: [], leftHand: [], rightHand: [], blendshapes: [] }, { mirror: true, smoothing: 0 }, 0);
    const trackedAngle = upperArm.quaternion.angleTo(new Quaternion());
    retargeter.update(null, { mirror: true, smoothing: 0 }, TRACKING_LOSS_GRACE_MS - 1);
    expect(upperArm.quaternion.angleTo(new Quaternion())).toBeCloseTo(trackedAngle);
    retargeter.update(null, { mirror: true, smoothing: 0 }, TRACKING_LOSS_GRACE_MS + 100);
    expect(upperArm.quaternion.angleTo(new Quaternion())).toBeLessThan(trackedAngle);
    expect(upperArm.quaternion.angleTo(new Quaternion())).toBeGreaterThan(0);
  });

  it("drives a VRM bone and expression from one motion frame", () => {
    const scene = new Object3D();
    const upperArm = new Object3D();
    const lowerArm = new Object3D();
    lowerArm.position.set(1, 0, 0);
    upperArm.add(lowerArm);
    scene.add(upperArm);
    const expressions = new Map<string, number>();
    const fakeVrm = {
      scene,
      humanoid: { getNormalizedBoneNode: (name: string) => name === "leftUpperArm" ? upperArm : null },
      expressionManager: {
        getValue: (name: string) => expressions.get(name),
        setValue: (name: string, value: number) => expressions.set(name, value),
      },
    } as unknown as VRM;
    const pose = Array.from({ length: 33 }, () => ({ x: 0, y: 0, z: 0, visibility: 1, presence: 1 })) satisfies Landmark[];
    pose[11] = { x: 0, y: 0, z: 0, visibility: 1, presence: 1 };
    pose[13] = { x: 0, y: 1, z: 0, visibility: 1, presence: 1 };
    pose[12] = { x: -1, y: 0, z: 0, visibility: 1, presence: 1 };
    pose[23] = { x: 0.5, y: 1, z: 0, visibility: 1, presence: 1 };
    pose[24] = { x: -0.5, y: 1, z: 0, visibility: 1, presence: 1 };
    const retargeter = new VrmRetargeter();
    retargeter.setVrm(fakeVrm);
    retargeter.update({
      pose,
      face: [],
      leftHand: [],
      rightHand: [],
      blendshapes: [{ categoryName: "jawOpen", score: 0.8, index: 0, displayName: "" }],
    }, { mirror: true, smoothing: 0 });
    expect(upperArm.quaternion.angleTo(new Quaternion())).toBeGreaterThan(1);
    expect(expressions.get("aa")).toBeCloseTo(0.8);
  });
});
