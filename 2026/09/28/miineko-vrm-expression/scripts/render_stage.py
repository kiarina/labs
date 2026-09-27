import bpy
import sys
from pathlib import Path
from mathutils import Vector

OUT=Path(__file__).resolve().parents[1]/"artifacts"
source=Path(sys.argv[sys.argv.index("--")+1])
bpy.ops.wm.open_mainfile(filepath=str(source))
scene=bpy.context.scene
cam=scene.camera
cam.data.ortho_scale=1.18
scene.render.resolution_x=1000
scene.render.resolution_y=1000
scene.render.resolution_percentage=100
for name,pos in (("front",(0,-2.5,.50)),("side",(2.5,0,.50)),("back",(0,2.5,.50))):
    cam.location=pos
    cam.rotation_euler=(Vector((0,0,.50))-cam.location).to_track_quat("-Z","Y").to_euler()
    scene.render.filepath=str(OUT/f"{source.stem}-{name}.png")
    bpy.ops.render.render(write_still=True)
    print(scene.render.filepath)
