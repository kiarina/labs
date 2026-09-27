#include "VrmReproDriver.h"

#include "Components/SkeletalMeshComponent.h"
#include "Components/StaticMeshComponent.h"
#include "AnimationRuntime.h"
#include "Dom/JsonObject.h"
#include "Engine/SkeletalMesh.h"
#include "Engine/StaticMesh.h"
#include "HAL/PlatformTime.h"
#include "UnrealClient.h"
#include "Kismet/GameplayStatics.h"
#include "GameFramework/PlayerController.h"
#include "LoaderBPFunctionLibrary.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Misc/CommandLine.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "VrmAssetListObject.h"
#include "VrmMetaObject.h"
#include "VrmReproAnimInstance.h"

DEFINE_LOG_CATEGORY_STATIC(LogVrmRepro, Log, All);

namespace
{
    constexpr float SettleSeconds = 2.f;
    constexpr float RampSeconds = 0.25f;    // accelerate to CruiseSpeed
    constexpr float MoveSeconds = 2.f;      // ramp + cruise
    constexpr float CruiseSpeed = 150.f;    // cm/s along +X
    constexpr float CruiseSampleFrom = 1.f; // average the trailing offset over [1 s, 2 s]

}

AVrmReproDriver::AVrmReproDriver()
{
    PrimaryActorTick.bCanEverTick = true;
    RootComponent = CreateDefaultSubobject<USceneComponent>(TEXT("Root"));
    Result = MakeShared<FJsonObject>();
}

void AVrmReproDriver::Tick(float DeltaSeconds)
{
    Super::Tick(DeltaSeconds);
    PhaseTime += DeltaSeconds;

    switch (Phase)
    {
    case EPhase::Warmup:
        if (PhaseTime > 0.5f)
        {
            FParse::Value(FCommandLine::Get(), TEXT("VrmReproScenario="), Scenario);
            FParse::Value(FCommandLine::Get(), TEXT("VrmReproOut="), OutPath);
            FString Tag;
            FParse::Value(FCommandLine::Get(), TEXT("VrmReproTag="), Tag);
            int32 Filler = 0;
            FParse::Value(FCommandLine::Get(), TEXT("VrmReproFiller="), Filler);
            Result->SetStringField(TEXT("scenario"), Scenario);
            Result->SetStringField(TEXT("tag"), Tag);
            Result->SetStringField(TEXT("world"), GetWorld()->IsPlayInEditor() ? TEXT("PIE") : TEXT("game"));
            Result->SetNumberField(TEXT("filler_components"), Filler);
            SpawnFiller(Filler);
            Phase = EPhase::Load;
            PhaseTime = 0.f;
        }
        break;

    case EPhase::Load:
        if (PhaseTime > 0.5f)
        {
            if (!LoadModel())
            {
                Finish(TEXT("load_failed"));
            }
            else if (Scenario == TEXT("spring"))
            {
                StartSpring();
                Phase = EPhase::Settle;
                PhaseTime = 0.f;
            }
            else if (FParse::Value(FCommandLine::Get(), TEXT("VrmReproShot="), ShotPath))
            {
                ShowModel();
                Phase = EPhase::Shot;
                PhaseTime = 0.f;
            }
            else
            {
                Finish(TEXT("ok"));
            }
        }
        break;

    case EPhase::Shot:
        if (PhaseTime >= 2.f && PhaseTime - DeltaSeconds < 2.f)
        {
            FScreenshotRequest::RequestScreenshot(ShotPath, false, false);
        }
        if (PhaseTime >= 3.f)
        {
            Result->SetStringField(TEXT("screenshot"), FPaths::GetCleanFilename(ShotPath));
            Finish(TEXT("ok"));
        }
        break;

    case EPhase::Settle:
        if (PhaseTime >= SettleSeconds)
        {
            MeasureRest();
            Phase = EPhase::Move;
            PhaseTime = 0.f;
        }
        break;

    case EPhase::Move:
    {
        const float Speed = CruiseSpeed * FMath::Min(PhaseTime / RampSeconds, 1.f);
        MoveX += Speed * DeltaSeconds;
        SetActorLocation(FVector(MoveX, 0.f, 0.f));
        SampleSpring(PhaseTime >= CruiseSampleFrom);
        if (PhaseTime >= MoveSeconds)
        {
            TArray<TSharedPtr<FJsonValue>> Items;
            float MaxRestAngle = 0.f;
            float MeanTrail = 0.f;
            for (const FTrackedSpring& Spring : Springs)
            {
                float Trail = 0.f;
                for (float V : Spring.CruiseOffsetX) { Trail += V; }
                Trail = Spring.CruiseOffsetX.Num() ? Trail / Spring.CruiseOffsetX.Num() : 0.f;
                TSharedPtr<FJsonObject> Item = MakeShared<FJsonObject>();
                Item->SetStringField(TEXT("spring"), Spring.Name);
                Item->SetNumberField(TEXT("joints"), Spring.JointBones.Num());
                Item->SetNumberField(TEXT("rest_max_angle_deg"), Spring.RestMaxAngleDeg);
                Item->SetNumberField(TEXT("rest_tail_offset_cm"), Spring.RestTailOffsetCm);
                Item->SetNumberField(TEXT("cruise_tail_offset_x_cm"), Trail);
                Items.Add(MakeShared<FJsonValueObject>(Item));
                MaxRestAngle = FMath::Max(MaxRestAngle, Spring.RestMaxAngleDeg);
                MeanTrail += Trail;
                UE_LOG(LogVrmRepro, Display, TEXT("VRMREPRO spring=%s joints=%d restMaxAngle=%.2fdeg restTailOffset=%.2fcm cruiseTailOffsetX=%.2fcm"),
                    *Spring.Name, Spring.JointBones.Num(), Spring.RestMaxAngleDeg, Spring.RestTailOffsetCm, Trail);
            }
            Result->SetArrayField(TEXT("springs"), Items);
            Result->SetNumberField(TEXT("rest_max_angle_deg"), MaxRestAngle);
            Result->SetNumberField(TEXT("mean_cruise_tail_offset_x_cm"), Springs.Num() ? MeanTrail / Springs.Num() : 0.f);
            Result->SetNumberField(TEXT("cruise_speed_cm_s"), CruiseSpeed);
            Finish(TEXT("ok"));
        }
        break;
    }

    case EPhase::Done:
        break;
    }
}

void AVrmReproDriver::SpawnFiller(int32 Count)
{
    UStaticMesh* Cube = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Cube.Cube"));
    UMaterialInterface* Material = LoadObject<UMaterialInterface>(nullptr, TEXT("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
    for (int32 i = 0; i < Count; ++i)
    {
        UStaticMeshComponent* Component = NewObject<UStaticMeshComponent>(this);
        Component->SetStaticMesh(Cube);
        Component->SetMaterial(0, UMaterialInstanceDynamic::Create(Material, Component));
        Component->SetupAttachment(RootComponent);
        Component->SetRelativeLocation(FVector(1000.f + (i % 50) * 120.f, -3000.f + (i / 50) * 120.f, -500.f));
        Component->RegisterComponent();
    }
}

bool AVrmReproDriver::LoadModel()
{
    FString Path;
    FParse::Value(FCommandLine::Get(), TEXT("VrmReproFile="), Path);
    TArray<uint8> Bytes;
    if (!FFileHelper::LoadFileToArray(Bytes, *Path))
    {
        UE_LOG(LogVrmRepro, Error, TEXT("VRMREPRO cannot read %s"), *Path);
        return false;
    }
    UClass* TemplateClass = LoadClass<UVrmAssetListObject>(nullptr, TEXT("/VRM4U/VrmAssetListObjectBP.VrmAssetListObjectBP_C"));
    UVrmAssetListObject* Template = NewObject<UVrmAssetListObject>(GetTransientPackage(), TemplateClass);
    UVrmAssetListObject* Out = nullptr;

    UE_LOG(LogVrmRepro, Display, TEXT("VRMREPRO load begin %s (%d bytes)"), *FPaths::GetCleanFilename(Path), Bytes.Num());
    const double Start = FPlatformTime::Seconds();
    const bool bOk = ULoaderBPFunctionLibrary::LoadVRMFileFromMemory(
        Template, Out, FPaths::GetCleanFilename(Path), Bytes.GetData(), static_cast<size_t>(Bytes.Num()));
    const double Seconds = FPlatformTime::Seconds() - Start;
    UE_LOG(LogVrmRepro, Display, TEXT("VRMREPRO load end ok=%d seconds=%.3f"), bOk ? 1 : 0, Seconds);

    Result->SetStringField(TEXT("model"), FPaths::GetCleanFilename(Path));
    Result->SetNumberField(TEXT("load_seconds"), Seconds);
    if (!bOk || !Out || !Out->SkeletalMesh)
    {
        return false;
    }
    AssetList = Out;
    Result->SetNumberField(TEXT("materials"), Out->Materials.Num());
    Result->SetNumberField(TEXT("textures"), Out->Textures.Num());
    Result->SetNumberField(TEXT("morph_targets"), Out->SkeletalMesh->GetMorphTargets().Num());
    return true;
}

void AVrmReproDriver::ShowModel()
{
    // Fixed camera looking at the model's upper body from the front.
    USkeletalMeshComponent* Shown = NewObject<USkeletalMeshComponent>(this);
    Shown->SetupAttachment(RootComponent);
    Shown->SetSkeletalMesh(AssetList->SkeletalMesh);
    Shown->SetRelativeLocation(FVector(0.f, 0.f, 0.f));
    Shown->RegisterComponent();
    if (APlayerController* PC = UGameplayStatics::GetPlayerController(this, 0))
    {
        PC->SetIgnoreMoveInput(true);
        PC->SetIgnoreLookInput(true);
        if (APawn* Pawn = PC->GetPawn())
        {
            Pawn->DisableInput(PC);
        }
        const FVector Eye(0.f, 150.f, 130.f);
        const FVector Target(0.f, 0.f, 120.f);
        PC->SetControlRotation((Target - Eye).Rotation());
        if (APawn* Pawn = PC->GetPawn())
        {
            Pawn->SetActorLocation(Eye);
        }
    }
}

void AVrmReproDriver::StartSpring()
{
    UVrmMetaObject* Meta = AssetList->VrmMetaObject;
    Mesh = NewObject<USkeletalMeshComponent>(this);
    Mesh->SetupAttachment(RootComponent);
    Mesh->VisibilityBasedAnimTickOption = EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones;
    Mesh->SetSkeletalMesh(AssetList->SkeletalMesh);
    Mesh->SetAnimInstanceClass(UVrmReproAnimInstance::StaticClass());
    Mesh->RegisterComponent();
    CastChecked<UVrmReproAnimInstance>(Mesh->GetAnimInstance())->Meta = Meta;

    const FReferenceSkeleton& RefSkeleton = AssetList->SkeletalMesh->GetRefSkeleton();
    for (const FVRM1SpringMeta& Spring : Meta->VRM1SpringBoneMeta.Springs)
    {
        FTrackedSpring& Tracked = Springs.AddDefaulted_GetRef();
        for (const FVRM1SpringJointMeta& Joint : Spring.joints)
        {
            const int32 Bone = RefSkeleton.FindBoneIndex(FName(*Joint.boneName));
            if (Bone != INDEX_NONE)
            {
                Tracked.JointBones.Add(Bone);
            }
        }
        Tracked.Name = Tracked.JointBones.Num()
            ? RefSkeleton.GetBoneName(Tracked.JointBones[0]).ToString() : TEXT("(unresolved)");
        if (Tracked.JointBones.Num() < 2)
        {
            Springs.Pop();
        }
    }
    Result->SetNumberField(TEXT("vrm_version"), Meta->GetVRMVersion());
    Result->SetNumberField(TEXT("vrm1_springs"), Meta->VRM1SpringBoneMeta.Springs.Num());
    int32 Joints = 0;
    for (const FVRM1SpringMeta& Spring : Meta->VRM1SpringBoneMeta.Springs) { Joints += Spring.joints.Num(); }
    Result->SetNumberField(TEXT("vrm1_joints"), Joints);
}

void AVrmReproDriver::MeasureRest()
{
    const FReferenceSkeleton& RefSkeleton = AssetList->SkeletalMesh->GetRefSkeleton();
    for (FTrackedSpring& Spring : Springs)
    {
        for (int32 Bone : Spring.JointBones)
        {
            const FTransform Rest = FAnimationRuntime::GetComponentSpaceTransformRefPose(RefSkeleton, Bone);
            const FTransform Now = Mesh->GetBoneTransform(Bone, FTransform::Identity);
            const float Angle = FMath::RadiansToDegrees(Rest.GetRotation().AngularDistance(Now.GetRotation()));
            Spring.RestMaxAngleDeg = FMath::Max(Spring.RestMaxAngleDeg, Angle);
        }
        const int32 Tail = Spring.JointBones.Last();
        Spring.SettledTail = Mesh->GetBoneTransform(Tail, FTransform::Identity).GetLocation();
        Spring.RestTailOffsetCm = FVector::Dist(Spring.SettledTail,
            FAnimationRuntime::GetComponentSpaceTransformRefPose(RefSkeleton, Tail).GetLocation());
    }
}

void AVrmReproDriver::SampleSpring(bool bCruise)
{
    if (!bCruise)
    {
        return;
    }
    for (FTrackedSpring& Spring : Springs)
    {
        const FVector Now = Mesh->GetBoneTransform(Spring.JointBones.Last(), FTransform::Identity).GetLocation();
        Spring.CruiseOffsetX.Add(Now.X - Spring.SettledTail.X);
    }
}

void AVrmReproDriver::Finish(const FString& Status)
{
    Phase = EPhase::Done;
    Result->SetStringField(TEXT("status"), Status);
    FString Json;
    const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Json);
    FJsonSerializer::Serialize(Result.ToSharedRef(), Writer);
    if (!OutPath.IsEmpty())
    {
        FFileHelper::SaveStringToFile(Json, *OutPath);
    }
    UE_LOG(LogVrmRepro, Display, TEXT("VRMREPRO result %s"), *Json);
    RequestEngineExit(TEXT("VrmRepro finished"));
}
