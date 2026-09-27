using UnrealBuildTool;

public class VrmRepro : ModuleRules
{
    public VrmRepro(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new[]
        {
            "Core",
            "CoreUObject",
            "Engine",
            "InputCore",
            "AnimGraphRuntime",
            "Json",
            "VRM4U",
            "VRM4ULoader"
        });
    }
}
