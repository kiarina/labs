#!/usr/bin/env python3

import json
from pathlib import Path


root = Path(__file__).resolve().parent
project_root = root / "UnrealProject"
project_file = project_root / "MixedAudioAttention.uproject"
required_files = [
    project_file,
    project_root / "Config" / "DefaultEditorPerProjectUserSettings.ini",
    project_root / "Source" / "MixedAudioAttention.Target.cs",
    project_root / "Source" / "MixedAudioAttentionEditor.Target.cs",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttention.Build.cs",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttention.cpp",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttention.h",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionSignal.cpp",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionExperiment.cpp",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionHUD.cpp",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionPawn.cpp",
    project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionGameMode.cpp",
]

missing = [str(path.relative_to(root)) for path in required_files if not path.is_file()]
if missing:
    raise SystemExit("missing required files: " + ", ".join(missing))

project = json.loads(project_file.read_text(encoding="utf-8"))
modules = {module.get("Name") for module in project.get("Modules", [])}
plugins = {plugin.get("Name") for plugin in project.get("Plugins", []) if plugin.get("Enabled")}
if "MixedAudioAttention" not in modules:
    raise SystemExit("runtime module is not enabled in the uproject")
for required_plugin in ("ModelContextProtocol", "AllToolsets", "ResonanceAudio"):
    if required_plugin not in plugins:
        raise SystemExit(f"required plugin is not enabled: {required_plugin}")

build_rules = (project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttention.Build.cs").read_text()
for module in ("AudioMixer", "SignalProcessing", "Json"):
    if f'"{module}"' not in build_rules:
        raise SystemExit(f"required build dependency is missing: {module}")

engine_config = (project_root / "Config" / "DefaultEngine.ini").read_text()
for setting in ("SpatializationPlugin=Resonance Audio", "QualityMode=BINAURAL_HIGH"):
    if setting not in engine_config:
        raise SystemExit(f"required engine setting is missing: {setting}")

editor_config = (project_root / "Config" / "DefaultEditorPerProjectUserSettings.ini").read_text()
if "GameGetsMouseControl=True" not in editor_config:
    raise SystemExit("PIE must transfer keyboard and mouse focus to the game viewport")

pawn_source = (project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionPawn.cpp").read_text()
for key_check in ("EKeys::W", "EKeys::S", "EKeys::A", "EKeys::D", "GetInputMouseDelta", "AddActorWorldOffset"):
    if key_check not in pawn_source:
        raise SystemExit(f"direct block-pawn input is missing: {key_check}")

experiment_source = (project_root / "Source" / "MixedAudioAttention" / "MixedAudioAttentionExperiment.cpp").read_text()
for source_behavior in (
    "OnActivationBeginOverlap",
    "SetCollisionResponseToChannel(ECC_Pawn, ECR_Overlap)",
    "ConfigureBurst(bFullExperiment)",
    'TEXT("ENV")',
    "BURST",
    "Settings.bAttenuate = false",
):
    if source_behavior not in experiment_source:
        raise SystemExit(f"interactive source behavior is missing: {source_behavior}")

generated_directories = ("Binaries", "DerivedDataCache", "Intermediate", "Saved")
unexpected = [name for name in generated_directories if (project_root / name).exists()]
if unexpected:
    print("generated directories present and ignored: " + ", ".join(unexpected))

print("project structure: ok")
print("runtime module: MixedAudioAttention")
print("MCP endpoint: http://127.0.0.1:8100/mcp")
