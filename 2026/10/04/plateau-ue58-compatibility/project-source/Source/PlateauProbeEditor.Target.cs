using UnrealBuildTool;
public class PlateauProbeEditorTarget : TargetRules { public PlateauProbeEditorTarget(TargetInfo Target) : base(Target) { Type = TargetType.Editor; DefaultBuildSettings = BuildSettingsVersion.V7; IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8; ExtraModuleNames.Add("PlateauProbe"); } }
