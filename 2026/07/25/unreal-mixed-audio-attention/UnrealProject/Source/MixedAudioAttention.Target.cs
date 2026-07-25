using UnrealBuildTool;

public class MixedAudioAttentionTarget : TargetRules
{
    public MixedAudioAttentionTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Game;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("MixedAudioAttention");
    }
}
