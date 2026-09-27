# Runs at Editor startup (PythonScriptPlugin executes Content/Python/init_unreal.py).
#   -VrmReproPIE                       enter Play In Editor once (the C++ driver does the rest)
#   -VrmReproImport=<out.json>         editor-import -VrmReproFile, report what was created, quit
# Without either flag this does nothing.
import json
import re

import unreal

command_line = unreal.SystemLibrary.get_command_line()


def arg(name):
    match = re.search(r'-%s=("[^"]*"|\S+)' % name, command_line, re.IGNORECASE)
    return match.group(1).strip('"') if match else None


if "-vrmrepropie" in command_line.lower():
    unreal.get_editor_subsystem(unreal.LevelEditorSubsystem).editor_request_begin_play()

import_out = arg("VrmReproImport")
if import_out:
    state = {"ticks": 0}

    def run_import(_delta):
        state["ticks"] += 1
        if state["ticks"] != 30:  # let the Editor finish starting up
            return
        result = {"source": arg("VrmReproFile").split("/")[-1]}
        try:
            asset_list = unreal.VrmImporterBPFunctionLibrary.import_vrm_file_with_options(
                arg("VrmReproFile"), "/Game/ImportCheck/SeedSan", unreal.ImportOptionData())
            mesh = asset_list.get_editor_property("skeletal_mesh") if asset_list else None
            post = mesh.get_editor_property("post_process_anim_blueprint") if mesh else None
            result.update({
                "status": "ok" if mesh else "import_failed",
                "skeletal_mesh": mesh.get_path_name() if mesh else None,
                "post_process_anim_blueprint": post.get_path_name() if post else None,
                "morph_targets": len(mesh.get_editor_property("morph_targets")) if mesh else 0,
            })
        except Exception as error:  # report, never hang the run
            result.update({"status": "exception", "error": str(error)})
        with open(import_out, "w") as f:
            json.dump(result, f, indent=2)
        unreal.log("VRMREPRO import result " + json.dumps(result))
        unreal.SystemLibrary.quit_editor()

    unreal.register_slate_post_tick_callback(run_import)
