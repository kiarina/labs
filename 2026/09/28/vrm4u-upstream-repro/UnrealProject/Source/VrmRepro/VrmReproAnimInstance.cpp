#include "VrmReproAnimInstance.h"

#include "Animation/AnimInstanceProxy.h"
#include "AnimNode_VrmSpringBone.h"
#include "BonePose.h"
#include "VrmMetaObject.h"
#include "Engine/World.h"

namespace
{
    void ToLocalPoses(const FCSPose<FCompactPose>& InPose, FCompactPose& OutPose)
    {
        OutPose = InPose.GetPose();
        const int32 NumBones = InPose.GetPose().GetNumBones();
        for (int32 Index = NumBones - 1; Index > 0; --Index)
        {
            const FCompactPoseBoneIndex BoneIndex(Index);
            if (InPose.GetComponentSpaceFlags()[BoneIndex])
            {
                const FCompactPoseBoneIndex ParentIndex = InPose.GetPose().GetParentBoneIndex(BoneIndex);
                OutPose[BoneIndex].SetToRelativeTransform(OutPose[ParentIndex]);
                OutPose[BoneIndex].NormalizeRotation();
            }
        }
    }

    class FVrmReproAnimProxy : public FAnimInstanceProxy
    {
    public:
        explicit FVrmReproAnimProxy(UAnimInstance* InInstance)
            : FAnimInstanceProxy(InInstance)
        {
        }

        virtual void PreUpdate(UAnimInstance* InAnimInstance, float DeltaSeconds) override
        {
            FAnimInstanceProxy::PreUpdate(InAnimInstance, DeltaSeconds);
            const UVrmReproAnimInstance* Instance = CastChecked<UVrmReproAnimInstance>(InAnimInstance);
            Meta = Instance->Meta;
            bNoGravityNoWind = Instance->bNoGravityNoWind;
            DeltaTime = Instance->SpringDeltaSeconds;
        }

        virtual bool Evaluate(FPoseContext& Output) override
        {
            Output.ResetToRefPose();
            if (!Meta)
            {
                return true;
            }
            if (!Spring.IsValid())
            {
                Spring = MakeShared<FAnimNode_VrmSpringBone>();
            }
            FAnimNode_VrmSpringBone& Node = *Spring;
            Node.VrmMetaObject_Internal = Meta;
            Node.bCallByAnimInstance = true;
            Node.CurrentDeltaTime = DeltaTime;
            if (bNoGravityNoWind)
            {
                Node.gravityScale = 0.f;
                Node.randomWindRange = 0.f;
                Node.windScale = 0.f;
                Node.bIgnoreWindDirectionalSource = true;
                Node.bIgnoreVRMCollision = true;
            }

            FAnimationInitializeContext InitContext(this);
            if (!Node.IsSpringInit())
            {
                Node.Initialize_AnyThread_local(InitContext);
                Node.ComponentPose.SetLinkNode(&Node);
                WarmupCount = 0;
                Node.CurrentDeltaTime = 1.f / 20.f;
            }

            const int32 Iterations = WarmupCount < 3 ? 20 : 1;
            WarmupCount = FMath::Min(WarmupCount + 1, 3);
            FComponentSpacePoseContext CSPose(this);
            for (int32 i = 0; i < Iterations; ++i)
            {
                CSPose.Pose.InitPose(Output.Pose);
                Node.EvaluateComponentSpace_AnyThread(CSPose);
                ToLocalPoses(CSPose.Pose, Output.Pose);
            }
            return true;
        }

    private:
        TSharedPtr<FAnimNode_VrmSpringBone> Spring;
        UVrmMetaObject* Meta = nullptr;
        float DeltaTime = 0.f;
        bool bNoGravityNoWind = true;
        int32 WarmupCount = 0;
    };
}

UVrmReproAnimInstance::UVrmReproAnimInstance(const FObjectInitializer& ObjectInitializer)
    : Super(ObjectInitializer)
{
    bUseMultiThreadedAnimationUpdate = false;
}

void UVrmReproAnimInstance::NativeUpdateAnimation(float DeltaSeconds)
{
    Super::NativeUpdateAnimation(DeltaSeconds);
    // The spring solver integrates with this step; a zero step freezes it.
    SpringDeltaSeconds = DeltaSeconds > 0.f ? DeltaSeconds : (GetWorld() ? GetWorld()->GetDeltaSeconds() : 0.f);
}

FAnimInstanceProxy* UVrmReproAnimInstance::CreateAnimInstanceProxy()
{
    return new FVrmReproAnimProxy(this);
}
