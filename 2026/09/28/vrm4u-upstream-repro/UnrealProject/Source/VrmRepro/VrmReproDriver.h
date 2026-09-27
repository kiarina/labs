#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "VrmReproDriver.generated.h"

class UVrmAssetListObject;
class USkeletalMeshComponent;

// Drives one scenario from the command line and writes a JSON result.
//   -VrmRepro                        enable (otherwise the lab does nothing)
//   -VrmReproFile=<path.vrm>         model to runtime-load
//   -VrmReproOut=<path.json>         result file
//   -VrmReproScenario=load|spring    load only, or load + spring response
//   -VrmReproFiller=<N>              static mesh components to keep in the world
//   -VrmReproTag=<text>              copied into the result (which fixes were applied)
//   -VrmReproShot=<path.png>         load scenario: show the model and save a screenshot
UCLASS()
class AVrmReproDriver : public AActor
{
    GENERATED_BODY()

public:
    AVrmReproDriver();
    virtual void Tick(float DeltaSeconds) override;

private:
    enum class EPhase : uint8 { Warmup, Load, Settle, Move, Shot, Done };

    void SpawnFiller(int32 Count);
    bool LoadModel();
    void StartSpring();
    void ShowModel();
    FString ShotPath;
    void MeasureRest();
    void SampleSpring(bool bCruise);
    void Finish(const FString& Status);

    EPhase Phase = EPhase::Warmup;
    float PhaseTime = 0.f;
    FString Scenario;
    FString OutPath;
    TSharedPtr<class FJsonObject> Result;

    UPROPERTY(Transient)
    TObjectPtr<UVrmAssetListObject> AssetList;

    UPROPERTY(Transient)
    TObjectPtr<USkeletalMeshComponent> Mesh;

    struct FTrackedSpring
    {
        FString Name;
        TArray<int32> JointBones;
        FVector SettledTail = FVector::ZeroVector;
        TArray<float> CruiseOffsetX;
        float RestMaxAngleDeg = 0.f;
        float RestTailOffsetCm = 0.f;
    };
    TArray<FTrackedSpring> Springs;
    float MoveX = 0.f;
};
