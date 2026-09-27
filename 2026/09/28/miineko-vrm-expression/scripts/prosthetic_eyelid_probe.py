"""Smooth fitted prosthetic eyelids on an otherwise untouched Tripo head."""

import bpy
import math
from pathlib import Path


out = Path(__file__).resolve().parents[1] / "artifacts"
bpy.ops.wm.open_mainfile(filepath=str(out / "mask-probe.blend"))
source = next(obj for obj in bpy.data.objects if obj.type == "MESH" and obj.name != "Miineko_Face_Mask_Neutral")
bpy.data.objects["Miineko_Face_Mask_Neutral"].hide_render = True


def face_y(x, z):
    q = z - 0.64
    return (-0.286787297 - 0.000335269*x + 0.0758551227*q
            + 1.20671255*x*x + 1.16455271*q*q + 0.0002285975*x*q)


def smooth(t):
    t = max(0, min(1, t))
    return t*t*(3-2*t)


source.shape_key_add(name="Basis")
recess = source.shape_key_add(name="BlinkEyesRecess")
for vertex in source.data.vertices:
    p = vertex.co
    r = min(math.sqrt(((p.x-side*0.15)/0.12)**2 + ((p.z-0.62)/0.11)**2) for side in (1,-1))
    weight = smooth((1.24-r)/0.32)*smooth((-p.y-0.18)/0.05)
    fitted = face_y(p.x,p.z)+0.015
    recess.data[vertex.index].co.y = p.y+(max(p.y,fitted)-p.y)*weight

skin = bpy.data.materials.new("Prosthetic Skin")
skin.diffuse_color = (0.84, 0.001, 0.251, 1)
skin.use_nodes = True
skin.blend_method = "BLEND"
skin.surface_render_method = "BLENDED"
bsdf = next(node for node in skin.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
bsdf.inputs["Base Color"].default_value = (0.84, 0.001, 0.251, 1)
bsdf.inputs["Roughness"].default_value = 0.7
alpha_node = skin.node_tree.nodes.new("ShaderNodeAttribute")
alpha_node.attribute_name = "CapAlpha"
skin.node_tree.links.new(alpha_node.outputs["Alpha"], bsdf.inputs["Alpha"])

black = bpy.data.materials.new("Closed Eye Ink")
black.diffuse_color = (0.004, 0.002, 0.004, 1)
black.use_nodes = True
black_bsdf = next(node for node in black.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
black_bsdf.inputs["Base Color"].default_value = (0.004, 0.002, 0.004, 1)
black_bsdf.inputs["Roughness"].default_value = 0.7


def cap(side):
    cx = side*0.15
    rings = 20
    segments = 96
    verts = [(cx, face_y(cx, 0.62)-0.002, 0.62)]
    faces = []
    for ri in range(1, rings+1):
        r = ri/rings
        for j in range(segments):
            a = 2*math.pi*j/segments
            x = cx+0.142*r*math.cos(a)
            z = 0.62+0.132*r*math.sin(a)
            y = face_y(x, z)-0.002
            verts.append((x,y,z))
    for j in range(segments):
        faces.append((0,1+j,1+(j+1)%segments))
    for ri in range(1,rings):
        for j in range(segments):
            a=1+(ri-1)*segments+j
            b=1+(ri-1)*segments+(j+1)%segments
            c=1+ri*segments+(j+1)%segments
            d=1+ri*segments+j
            faces.append((a,b,c,d))
    mesh = bpy.data.meshes.new(f"Eyelid_Skin_{side}")
    mesh.from_pydata(verts,[],faces)
    mesh.update()
    obj = bpy.data.objects.new(f"Prosthetic_Eyelid_{'L' if side>0 else 'R'}", mesh)
    bpy.context.collection.objects.link(obj)
    mesh.materials.append(skin)
    for poly in mesh.polygons:
        poly.use_smooth = True
    alphas = mesh.color_attributes.new(name="CapAlpha",type="FLOAT_COLOR",domain="CORNER")
    for loop in mesh.loops:
        p = mesh.vertices[loop.vertex_index].co
        r = math.sqrt(((p.x-cx)/0.142)**2+((p.z-0.62)/0.132)**2)
        alphas.data[loop.index].color = (1,1,1,1-smooth((r-0.80)/0.18))
    uv = mesh.uv_layers.new(name="FaceLocal")
    for loop in mesh.loops:
        p = mesh.vertices[loop.vertex_index].co
        uv.data[loop.index].uv = (0.5+(p.x-cx)/0.284,0.5+(p.z-0.62)/0.264)
    return obj


caps = [cap(1),cap(-1)]
lines=[]
for side in (1,-1):
    curve = bpy.data.curves.new("Closed Eye Line","CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = 0.0025
    curve.bevel_resolution = 3
    spline = curve.splines.new("POLY")
    spline.points.add(1)
    for i,p in enumerate(spline.points):
        x = side*0.15+(i-0.5)*0.11
        z = 0.62
        p.co = (x,face_y(side*0.15,z)-0.010,z,1)
    line = bpy.data.objects.new(f"Prosthetic_Line_{side}",curve)
    bpy.context.collection.objects.link(line)
    curve.materials.append(black)
    lines.append(line)

scene = bpy.context.scene
for obj in caps+lines:
    obj.hide_render = True
source.data.shape_keys.key_blocks["BlinkEyesRecess"].value = 0
scene.render.filepath = str(out/"prosthetic-neutral.png")
bpy.ops.render.render(write_still=True)
for obj in caps+lines:
    obj.hide_render = False
source.data.shape_keys.key_blocks["BlinkEyesRecess"].value = 1
scene.render.filepath = str(out/"prosthetic-closed.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out/"prosthetic-probe.blend"))
