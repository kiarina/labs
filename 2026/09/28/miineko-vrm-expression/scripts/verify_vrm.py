import json
import struct
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]/"artifacts"
data=(ROOT/"miineko.vrm").read_bytes()
magic,version,total=struct.unpack_from("<4sII",data,0)
assert magic==b"glTF" and version==2 and total==len(data)
offset=12
payload=None
while offset<len(data):
    size,kind=struct.unpack_from("<I4s",data,offset)
    offset+=8
    if kind==b"JSON":payload=json.loads(data[offset:offset+size])
    offset+=size
assert payload is not None
vrm=payload["extensions"]["VRMC_vrm"]
springs=payload["extensions"].get("VRMC_springBone",{})
preset=vrm.get("expressions",{}).get("preset",{})
required=("happy","angry","sad","relaxed","surprised","blink","blinkLeft","blinkRight",
          "aa","ih","ou","ee","oh","lookUp","lookDown","lookLeft","lookRight")
bindings={name:len(preset.get(name,{}).get("morphTargetBinds",[])) for name in required}
assert all(bindings.values()),bindings
assert vrm["lookAt"]["type"]=="bone"
assert len(springs.get("springs",[]))==3
assert len(vrm["humanoid"]["humanBones"])>=15
report={"bytes":len(data),"specVersion":vrm["specVersion"],"meshCount":len(payload["meshes"]),
        "boneAssignments":vrm["humanoid"]["humanBones"],"expressionBindings":bindings,
        "lookAt":vrm["lookAt"],"springCount":len(springs["springs"]),
        "springJoints":[len(s["joints"]) for s in springs["springs"]],
        "materials":len(payload["materials"]),"images":len(payload["images"]),
        "externalUris":[x.get("uri") for x in payload.get("images",[]) if x.get("uri")]}
(ROOT/"vrm-report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print(json.dumps({k:v for k,v in report.items() if k!="boneAssignments" and k!="lookAt"},ensure_ascii=False,indent=2))
