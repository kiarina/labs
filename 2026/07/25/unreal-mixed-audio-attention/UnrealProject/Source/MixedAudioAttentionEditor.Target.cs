using UnrealBuildTool;

public class MixedAudioAttentionEditorTarget : TargetRules
{
    public MixedAudioAttentionEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("MixedAudioAttention");
    }
}
