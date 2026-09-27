"""Compare source-preserving material separation and continuous UV eyelids.

Run in background Blender after setup_vrm_base.py. All outputs are private,
ignored artifacts. This is a visual experiment, not a production converter.
"""

import json
import hashlib
import math
import os
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

RX = float(os.environ.get("BLINK_RX", ".112"))
RZ = float(os.environ.get("BLINK_RZ", ".115"))
CURVE = float(os.environ.get("BLINK_CURVE", "0"))
SHIFT = .027+RZ*2
APERTURE = os.environ.get("BLINK_APERTURE", "parallel")
assert APERTURE in ("parallel", "ellipse")
INK = os.environ.get("BLINK_INK", "uniform")
assert INK in ("uniform", "eye-local")

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts" / os.environ.get("BLINK_RUN", "continuous-blink")
OUT.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(ROOT / "artifacts/base-vrm.blend"))
body = bpy.data.objects["Miineko_Body"]
arm = bpy.data.objects["Miineko_Rig"]
original = body.data.materials[0]
scene = bpy.context.scene


def smooth(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def studio():
    world = bpy.data.worlds.new("Blink comparison studio")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes.clear()
    bg = world.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (.85, .85, .85, 1)
    bg.inputs[1].default_value = .8
    wo = world.node_tree.nodes.new("ShaderNodeOutputWorld")
    world.node_tree.links.new(bg.outputs[0], wo.inputs[0])
    for pos, energy, size in (((-1.2, -1.5, 2.5), 550, 2), ((1.5, -.4, 1.6), 320, 1.5)):
        data = bpy.data.lights.new("Comparison softbox", "AREA")
        data.energy, data.size, data.shape = energy, size, "DISK"
        obj = bpy.data.objects.new(data.name, data)
        bpy.context.collection.objects.link(obj)
        obj.location = pos
        obj.rotation_euler = (Vector((0, 0, .45)) - obj.location).to_track_quat("-Z", "Y").to_euler()
    data = bpy.data.cameras.new("Comparison camera")
    camera = bpy.data.objects.new(data.name, data)
    bpy.context.collection.objects.link(camera)
    data.type, data.ortho_scale = "ORTHO", .82
    scene.camera = camera
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.cycles.seed = 17
    scene.cycles.use_animated_seed = False
    scene.render.resolution_x = scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    return camera


camera = studio()


def render(name, angle=0):
    a = math.radians(angle)
    camera.location = (2.5 * math.sin(a), -2.5 * math.cos(a), .64)
    camera.rotation_euler = (Vector((0, 0, .64)) - camera.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(OUT / f"{name}-{angle}.png")
    bpy.ops.render.render(write_still=True)


views = [int(x) for x in os.environ.get("BLINK_VIEWS", "0,45,90").split(",")]
for angle in views:
    render("source", angle)

# Control: no new vertices, UVs, normals, maps or shader parameters.
centers = {"L": (.1764, .619), "R": (-.1848, .619)}
for side, (cx, cz) in centers.items():
    mat = original.copy()
    mat.name = f"Original eye material {side}"
    body.data.materials.append(mat)
    for poly in body.data.polygons:
        p = poly.center
        if p.y < -.1 and ((p.x - cx) / .12) ** 2 + ((p.z - cz) / .12) ** 2 < 1:
            poly.material_index = len(body.data.materials) - 1
for angle in views:
    render("material-split", angle)

# Ray-sample the source, then remove high frequency eye sculpting. No head
# replacement or normal-map baking occurs. The shell has a conservative forward
# envelope to avoid intersections; its resulting offset is measured below.
vertices = [v.co.copy() for v in body.data.vertices]
body.data.calc_loop_triangles()
triangles=list(body.data.loop_triangles)
bvh = BVHTree.FromPolygons(vertices, [list(t.vertices) for t in triangles], all_triangles=True)
source_image=next(n.image for n in original.node_tree.nodes if n.type=="TEX_IMAGE" and n.image and "BaseColor" in n.image.filepath)
source_pixels=np.empty(source_image.size[0]*source_image.size[1]*4,dtype=np.float32)
source_image.pixels.foreach_get(source_pixels)
source_pixels=source_pixels.reshape(source_image.size[1],source_image.size[0],4)

def sample_skin(x,z):
    hit=bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
    point,_,index,_=hit
    tri=triangles[index]
    a,b,c=[vertices[i] for i in tri.vertices]
    v0,v1,v2=b-a,c-a,point-a
    d00,d01,d11=v0.dot(v0),v0.dot(v1),v1.dot(v1)
    d20,d21=v2.dot(v0),v2.dot(v1)
    den=d00*d11-d01*d01
    wb=(d11*d20-d01*d21)/den
    wc=(d00*d21-d01*d20)/den
    coords=[body.data.uv_layers[0].data[i].uv for i in tri.loops]
    uv=coords[0]*(1-wb-wc)+coords[1]*wb+coords[2]*wc
    u=min(source_pixels.shape[1]-1,max(0,int(uv.x*source_pixels.shape[1])))
    v=min(source_pixels.shape[0]-1,max(0,int(uv.y*source_pixels.shape[0])))
    return source_pixels[v,u,:3]

def skin_rgb(cx,cz,x,z):
    raw=sample_skin(x,z)
    def pink(c): return c[0]>.65 and c[1]<.25 and c[2]>.2
    if not pink(raw):
        samples=[]
        for a in np.linspace(0,2*math.pi,64,endpoint=False):
            sx,sz=cx+.111*math.cos(a),cz+.113*math.sin(a)
            color=sample_skin(sx,sz)
            if pink(color):samples.append((color,1/(.002+(sx-x)**2+(sz-z)**2)))
        if not samples:raise RuntimeError("No pink skin samples around eye")
        raw=sum(c*w for c,w in samples)/sum(w for _,w in samples)
    return np.where(raw<=.04045,raw/12.92,((raw+.055)/1.055)**2.4)

method = os.environ.get("BLINK_METHOD", "wipe")
report = {"ink":INK,"aperture":APERTURE,"edge":os.environ.get("BLINK_EDGE","feather"), "skin":os.environ.get("BLINK_SKIN","constant"), "geometryControl": method, "surface": os.environ.get("BLINK_SURFACE", "envelope"), "blender": bpy.app.version_string, "method": "morph-lid" if method=="morph" else "continuous-alpha-wipe",
          "centers": centers, "grid": 65, "radius": [RX, RZ], "curve": CURVE, "sourceScriptSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "eyes": {}}


def surface(cx, cz):
    n = report["grid"]
    xx, zz = np.meshgrid(np.linspace(-RX, RX, n), np.linspace(-RZ, RZ, n))
    zz = zz + CURVE * (1-(xx/RX)**2)
    ys = np.empty_like(xx)
    for j in range(n):
        for i in range(n):
            hit = bvh.ray_cast(Vector((cx + xx[j, i], -1, cz + zz[j, i])), Vector((0, 1, 0)))
            if hit[0] is None:
                raise RuntimeError("Eyelid grid misses original surface")
            ys[j, i] = hit[0].y
    # Iterated heat smoothing suppresses cavities without fitting an unrelated
    # forehead plane. Borders stay fixed; restrict corrections to the eye disk.
    low = ys.copy()
    for _ in range(80):
        old = low.copy()
        low[1:-1, 1:-1] = .5 * old[1:-1, 1:-1] + .125 * (
            old[2:, 1:-1] + old[:-2, 1:-1] + old[1:-1, 2:] + old[1:-1, :-2])
        if os.environ.get("BLINK_SURFACE", "envelope") == "obstacle":
            low = np.minimum(low, ys)
    rr = np.sqrt((xx / RX) ** 2 + (zz / RZ) ** 2)
    if os.environ.get("BLINK_SURFACE") == "quadratic-eye":
        u, v = xx / RX, zz / RZ
        basis = np.stack([np.ones_like(u), u, v, u*u, u*v, v*v], axis=-1)
        core_fit = rr < .75
        design = basis[core_fit]
        target = ys[core_fit]
        weights = np.ones(len(target))
        for _ in range(8):
            coeff = np.linalg.lstsq(design * weights[:, None], target * weights, rcond=None)[0]
            residual = target - design @ coeff
            # Downweight deeper cavities; fit the undented eye surface.
            weights = np.where(residual > .002, .08, 1.)
        fitted = basis @ coeff
        transition = smooth((rr - .72) / .28)
        low = fitted * (1-transition) + low * transition
    core = rr < .83
    clearance = max(0, float(np.max((low - ys)[core]))) + .0006
    if os.environ.get("BLINK_EDGE") == "source":
        # End on the unchanged source surface, rather than floating over cheek.
        edge = smooth((rr-.75)/.17)
        low = low*(1-edge)+ys*edge
        depth = low - clearance*(1-smooth((rr-.70)/.22))-.0006
    else:
        depth = low - clearance * (1 - smooth((rr - .83) / .17)) - .0004
    if method == "hybrid":
        depth = low - .0006
    return xx, zz, depth, rr, {"maxEnvelopeOffset": clearance,
                             "maxForwardDistance": float(np.max(ys - depth))}


def wipe_image(side):
    # Algorithmic material ramp, not a rebake or edit of the source artwork.
    # Texture-space v>=0.5 is opaque; the leading edge is ink, then pink.
    height, width = 2048, (128 if INK == "eye-local" else 8)
    vv = (np.arange(height) + .5) / height
    alpha = smooth((vv - .5) / .002)
    ink = 1 - smooth((vv - .507) / .003)
    skin = np.ones(3) if os.environ.get("BLINK_SKIN")=="sampled" else np.array((.9215687, .00392157, .53333336))
    rgb = skin[None, :] * (1 - ink[:, None]) + .004 * ink[:, None]
    rgba = np.ones((height, width, 4), dtype=np.float32)
    rgba[:, :, :3] = rgb[:, None, :]
    rgba[:, :, 3] = alpha[:, None]
    if INK == "eye-local":
        # U controls a static ink mask; V still controls only the moving lid.
        # At the skin perimeter the moving edge is skin-colored rather than
        # drawing an extra black ring before it reaches the original eye.
        strength=np.linspace(0,1,width)[None,:,None]*ink[:,None,None]
        rgba[:,:,:3]=skin[None,None,:]*(1-strength)+.004*strength
    img = bpy.data.images.new(f"Eyelid ramp {side}", width=width, height=height, alpha=True)
    img.pixels.foreach_set(rgba.ravel())
    img.filepath_raw = str(OUT / f"ramp-{side}.png")
    img.file_format = "PNG"
    img.save()
    # Reload to use precisely the encoded pixels that will be exported.
    loaded = bpy.data.images.load(img.filepath_raw, check_existing=False)
    loaded.pack()
    return loaded


lids = []
maps = []
morphs = []
if method == "hybrid":
    body.shape_key_add(name="Basis")
for side, (cx, cz) in centers.items():
    xx, zz, yy, rr, stats = surface(cx, cz)
    report["eyes"][side] = stats
    n = len(xx)
    if method == "hybrid":
        key = body.shape_key_add(name=f"LidClearance{side}")
        for v in body.data.vertices:
            p = v.co
            fx = (p.x-cx+RX)/(2*RX)*(n-1)
            fz = (p.z-cz-CURVE*(1-((p.x-cx)/RX)**2)+RZ)/(2*RZ)*(n-1)
            if not (0<=fx<n-1 and 0<=fz<n-1 and p.y<-.10):
                continue
            i,j = int(fx),int(fz)
            tx,tz=fx-i,fz-j
            shell_y=(yy[j,i]*(1-tx)+yy[j,i+1]*tx)*(1-tz)+(yy[j+1,i]*(1-tx)+yy[j+1,i+1]*tx)*tz
            r=math.sqrt(((p.x-cx)/RX)**2+((p.z-cz)/RZ)**2)
            influence=float(1-smooth((r-.94)/.06))
            key.data[v.index].co.y += max(0,shell_y+.005-p.y)*influence
        morphs.append(key)
        for name in ("blink", "blink_left" if side=="L" else "blink_right"):
            bind=getattr(arm.data.vrm_addon_extension.vrm1.expressions.preset,name).morph_target_binds.add()
            bind.node.mesh_object_name=body.name
            bind.index=key.name
            bind.weight=1
    ramp = wipe_image(side)
    for direction, label in ((1, "upper"), (-1, "lower")):
        # Separate upper/lower half surfaces avoid alpha sorting at overlap.
        inds = {}
        verts, faces, uvcoords, opacity = [], [], [], []
        for j in range(n):
            for i in range(n):
                local_z = zz[j,i]-CURVE*(1-(xx[j,i]/RX)**2)
                if direction * local_z < -1e-8:
                    continue
                inds[j, i] = len(verts)
                verts.append((cx + xx[j, i], yy[j, i], cz + zz[j, i]))
                # At neutral max V=.475; at closure boundary V=.502.
                ink_u=.5
                if INK == "eye-local":
                    ink_radius=math.hypot(xx[j,i]/.087,zz[j,i]/.096)
                    ink_u=.5/128+(127/128)*float(smooth((1-ink_radius)/.13))
                if APERTURE == "ellipse":
                    # A single linear VRM offset now sweeps an elliptical
                    # opening. The ink tapers near the corners. Keep all UVs
                    # below the alpha threshold at neutral, even outside the
                    # geometric ellipse where vertex alpha fades to zero.
                    height = RZ * math.sqrt(max(.015, 1-(xx[j,i]/RX)**2))
                    q = min(1., direction*local_z/height)
                    uvcoords.append((ink_u, .475+(q-1)*RZ*2))
                else:
                    uvcoords.append((ink_u, .475 + (direction * local_z - RZ) * 2))
                opacity.append(float(1 - smooth((rr[j, i] - (.94 if os.environ.get("BLINK_EDGE")=="source" else .83)) / (.06 if os.environ.get("BLINK_EDGE")=="source" else .17))))
        for j in range(n - 1):
            for i in range(n - 1):
                corners = ((j, i), (j, i + 1), (j + 1, i + 1), (j + 1, i))
                if all(p in inds for p in corners):
                    faces.append(tuple(inds[p] for p in corners))
        mesh = bpy.data.meshes.new(f"Lid {side} {label}")
        mesh.from_pydata(verts, [], faces)
        mesh.update()
        obj = bpy.data.objects.new(mesh.name, mesh)
        bpy.context.collection.objects.link(obj)
        obj.parent = arm
        group = obj.vertex_groups.new(name="J_Bip_C_Head")
        group.add(list(range(len(verts))), 1, "REPLACE")
        obj.modifiers.new("Armature", "ARMATURE").object = arm
        for p in mesh.polygons:
            p.use_smooth = True
        uv = mesh.uv_layers.new(name="LidUV")
        colors = mesh.color_attributes.new(name="LidFeather", type="FLOAT_COLOR", domain="CORNER")
        vertex_rgb = [skin_rgb(cx,cz,v.co.x,v.co.z) for v in mesh.vertices] if os.environ.get("BLINK_SKIN")=="sampled" else None
        for loop in mesh.loops:
            uv.data[loop.index].uv = uvcoords[loop.vertex_index]
            if os.environ.get("BLINK_SKIN")=="sampled":
                pos=mesh.vertices[loop.vertex_index].co
                rgb=vertex_rgb[loop.vertex_index]
            else:
                rgb=(1,1,1)
            colors.data[loop.index].color = (*rgb, opacity[loop.vertex_index])
        mesh.color_attributes.active_color = colors
        lid_key = None
        if method == "morph":
            basis_key=obj.shape_key_add(name="Basis")
            lid_key=obj.shape_key_add(name="Close")
            for v in mesh.vertices:
                x=v.co.x-cx
                column=int(round((x+RX)/(2*RX)*(n-1)))
                collapsed=Vector((v.co.x,float(np.min(yy[:,column]))-.001,cz+direction*RZ*math.sqrt(max(0,1-(x/RX)**2))))
                basis_key.data[v.index].co=collapsed
                v.co=collapsed
            morphs.append(lid_key)
        mat = bpy.data.materials.new(mesh.name)
        mat.use_nodes = True
        mat.surface_render_method = "BLENDED"
        mat.use_backface_culling = False
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Roughness"].default_value = .7
        tex = nodes.new("ShaderNodeTexImage")
        tex.image, tex.extension = ramp, "EXTEND"
        coord = nodes.new("ShaderNodeTexCoord")
        mapping = nodes.new("ShaderNodeMapping")
        mapping.vector_type = "POINT"
        links.new(coord.outputs["UV"], mapping.inputs["Vector"])
        links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
        links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        color = nodes.new("ShaderNodeVertexColor")
        color.layer_name = "LidFeather"
        tint = nodes.new("ShaderNodeMix")
        tint.data_type = "RGBA"
        tint.blend_type = "MULTIPLY"
        tint.inputs[0].default_value = 1
        links.new(tex.outputs["Color"], tint.inputs[6])
        links.new(color.outputs["Color"], tint.inputs[7])
        links.new(tint.outputs[2], bsdf.inputs["Base Color"])
        multiply = nodes.new("ShaderNodeMath")
        multiply.operation = "MULTIPLY"
        links.new(tex.outputs["Alpha"], multiply.inputs[0])
        links.new(color.outputs["Alpha"], multiply.inputs[1])
        links.new(multiply.outputs[0], bsdf.inputs["Alpha"])
        mesh.materials.append(mat)
        if method == "morph":
            mapping.inputs["Location"].default_value.y=SHIFT
        else:
            maps.append(mapping)
        lids.append(obj)
        # glTF uses a top-left UV convention. The exporter flips base UVs;
        # VRM bind offsets are glTF coordinates and therefore use negative V.
        for name in ("blink", "blink_left" if side == "L" else "blink_right"):
            expr=getattr(arm.data.vrm_addon_extension.vrm1.expressions.preset, name)
            if method == "morph":
                bind=expr.morph_target_binds.add()
                bind.node.mesh_object_name=obj.name
                bind.index=lid_key.name
                bind.weight=1
            else:
                bind = expr.texture_transform_binds.add()
                bind.material = mat
                bind.scale = (1, 1)
                bind.offset = (0, -SHIFT)


for weight in (0, .25, .5, .75, 1):
    for mapping in maps:
        mapping.inputs["Location"].default_value.y = SHIFT * weight
    for key in morphs:
        key.value=weight
    for angle in views:
        render(f"wipe-{weight:g}", angle)
for mapping in maps:
    mapping.inputs["Location"].default_value.y = 0
for key in morphs:
    key.value=0
for img in bpy.data.images:
    if img.source == "FILE" and not img.packed_file:
        img.pack()
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "continuous-blink.blend"))
result = bpy.ops.export_scene.vrm(filepath=str(OUT / "continuous-blink.vrm"))
report["export"] = sorted(result)
(OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print("CONTINUOUS_BLINK", json.dumps(report))
