"""Render source and candidate with BaseColor only to separate shading errors."""
import bpy
import os
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts'/os.environ.get('BLINK_RUN','stitched-blink-dense')
for label,path in [('original',ROOT/'artifacts/base-vrm.blend'),('candidate',OUT/'continuous-blink.blend')]:
    bpy.ops.wm.open_mainfile(filepath=str(path))
    for mat in bpy.data.materials:
        if not mat.use_nodes:continue
        bsdf=next((n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED'),None)
        output=next((n for n in mat.node_tree.nodes if n.type=='OUTPUT_MATERIAL'),None)
        if not bsdf or not output:continue
        emission=mat.node_tree.nodes.new('ShaderNodeEmission')
        if bsdf.inputs['Base Color'].is_linked:
            mat.node_tree.links.new(bsdf.inputs['Base Color'].links[0].from_socket,emission.inputs['Color'])
        else:emission.inputs['Color'].default_value=bsdf.inputs['Base Color'].default_value
        mat.node_tree.links.new(emission.outputs[0],output.inputs['Surface'])
    scene=bpy.context.scene
    camera=scene.camera
    if camera is None:
        data=bpy.data.cameras.new('Unlit camera');camera=bpy.data.objects.new('Unlit camera',data);bpy.context.collection.objects.link(camera);scene.camera=camera
    camera.location=(0,-2.5,.64);camera.rotation_euler=(Vector((0,0,.64))-camera.location).to_track_quat('-Z','Y').to_euler();camera.data.type='ORTHO';camera.data.ortho_scale=.82
    scene.render.engine='CYCLES';scene.cycles.samples=8;scene.cycles.seed=17
    scene.render.resolution_x=scene.render.resolution_y=720;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.film_transparent=True
    scene.render.filepath=str(OUT/f'unlit-{label}.png');bpy.ops.render.render(write_still=True)
