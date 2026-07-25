using UnrealBuildTool;

public class MixedAudioAttention : ModuleRules
{
    public MixedAudioAttention(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new[]
        {
            "Core",
            "CoreUObject",
            "Engine",
            "InputCore",
            "AudioMixer",
            "SignalProcessing",
            "Json"
        });
    }
}
