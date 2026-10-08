using UnrealBuildTool;
public class PlateauProbeTarget : TargetRules { public PlateauProbeTarget(TargetInfo Target) : base(Target) { Type = TargetType.Game; DefaultBuildSettings = BuildSettingsVersion.V7; IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8; ExtraModuleNames.Add("PlateauProbe"); } }
