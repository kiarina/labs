from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


FRAMES = 120
FPS = 30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--glb", type=Path, required=True)
    parser.add_argument("--fov", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--target-distance", type=float, default=18.0)
    parser.add_argument("--camera-shift", type=float, default=0.8)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def point_camera(camera: bpy.types.Object, target: Vector) -> None:
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()


def configure_materials(meshes: list[bpy.types.Object]) -> None:
    for mesh in meshes:
        for material in mesh.data.materials:
            material.diffuse_color = (1.0, 1.0, 1.0, 1.0)
            material.metallic = 0.0
            material.roughness = 1.0
            nodes = material.node_tree.nodes
            links = material.node_tree.links
            principled = next(node for node in nodes if node.type == "BSDF_PRINCIPLED")
            texture = next(node for node in nodes if node.type == "TEX_IMAGE")
            links.new(texture.outputs["Color"], principled.inputs["Emission Color"])
            principled.inputs["Emission Strength"].default_value = 0.8


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=str(args.glb.resolve()))
    meshes = [item for item in bpy.context.scene.objects if item.type == "MESH"]
    if not meshes:
        raise RuntimeError("the GLB did not contain a mesh")
    configure_materials(meshes)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.fps = FPS
    scene.frame_start = 1
    scene.frame_end = FRAMES
    scene.render.filepath = str((args.output / "frames").resolve()) + "/"
    scene.render.image_settings.color_mode = "RGB"
    scene.view_settings.look = "AgX - Medium High Contrast"

    scene.world.color = (0.04, 0.04, 0.04)
    world_nodes = scene.world.node_tree.nodes
    world_nodes["Background"].inputs["Color"].default_value = (0.025, 0.025, 0.025, 1.0)
    world_nodes["Background"].inputs["Strength"].default_value = 0.8

    light_data = bpy.data.lights.new(name="Camera fill", type="AREA")
    light_data.energy = 900.0
    light_data.shape = "DISK"
    light_data.size = 8.0
    light = bpy.data.objects.new(name="Camera fill", object_data=light_data)
    scene.collection.objects.link(light)
    light.location = (0.0, -3.0, 7.0)
    light.rotation_euler = (math.radians(22), 0.0, 0.0)

    camera_data = bpy.data.cameras.new(name="Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    camera_data.sensor_fit = "HORIZONTAL"
    camera_data.angle = math.radians(json.loads(args.fov.read_text())["fov_x"])
    camera_data.lens = camera_data.lens
    camera_data.clip_start = 0.01
    camera_data.clip_end = 500.0

    target = Vector((0.0, args.target_distance, 1.0))
    shift = args.camera_shift
    keyframes = [
        (1, Vector((0.0, 0.0, 0.0))),
        (30, Vector((-shift, -shift * 0.3125, shift * 0.1875))),
        (60, Vector((0.0, 0.0, 0.0))),
        (90, Vector((shift, -shift * 0.3125, shift * 0.1875))),
        (120, Vector((0.0, 0.0, 0.0))),
    ]
    for frame, location in keyframes:
        camera.location = location
        point_camera(camera, target)
        camera.keyframe_insert(data_path="location", frame=frame)
        camera.keyframe_insert(data_path="rotation_euler", frame=frame)

    bpy.ops.wm.save_as_mainfile(filepath=str((args.output / f"{args.name}.blend").resolve()))
    bpy.ops.render.render(animation=True)


if __name__ == "__main__":
    main()
