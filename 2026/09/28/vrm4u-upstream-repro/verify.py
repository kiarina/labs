#!/usr/bin/env python3

import json
from pathlib import Path


root = Path(__file__).resolve().parent
project_root = root / "UnrealProject"
project_file = project_root / "VrmRepro.uproject"
required_files = [
    project_file,
    project_root / "Config" / "DefaultEditorPerProjectUserSettings.ini",
    project_root / "Source" / "VrmRepro.Target.cs",
    project_root / "Source" / "VrmReproEditor.Target.cs",
    project_root / "Source" / "VrmRepro" / "VrmRepro.Build.cs",
    project_root / "Source" / "VrmRepro" / "VrmRepro.cpp",
    project_root / "Source" / "VrmRepro" / "VrmRepro.h",
]

missing = [str(path.relative_to(root)) for path in required_files if not path.is_file()]
if missing:
    raise SystemExit("missing required files: " + ", ".join(missing))

project = json.loads(project_file.read_text(encoding="utf-8"))
modules = {module.get("Name") for module in project.get("Modules", [])}
plugins = {plugin.get("Name") for plugin in project.get("Plugins", []) if plugin.get("Enabled")}
if "VrmRepro" not in modules:
    raise SystemExit("runtime module is not enabled in the uproject")
for required_plugin in ("ModelContextProtocol", "AllToolsets", "VRM4U", "PythonScriptPlugin"):
    if required_plugin not in plugins:
        raise SystemExit(f"required plugin is not enabled: {required_plugin}")

for patch in ("00-mac-build", "01-runtime-curve-metadata-no-transaction", "02-runtime-skip-postprocess-abp",
              "03-runtime-skip-material-update-context", "04-vrm1-spring-head-tail-axis"):
    if not (root / "patches" / f"{patch}.patch").is_file():
        raise SystemExit(f"missing patch: {patch}")

generated_directories = ("Binaries", "DerivedDataCache", "Intermediate", "Saved", "Plugins")
unexpected = [name for name in generated_directories if (project_root / name).exists()]
if unexpected:
    print("generated directories present and ignored: " + ", ".join(unexpected))

print("project structure: ok")
print("runtime module: VrmRepro")
print("MCP endpoint: http://127.0.0.1:8101/mcp")
