using UnrealBuildTool;

public class VrmReproEditorTarget : TargetRules
{
    public VrmReproEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("VrmRepro");
    }
}
