#pragma once

#include "CoreMinimal.h"
#include "Animation/AnimInstance.h"
#include "VrmReproAnimInstance.generated.h"

class UVrmMetaObject;

// Rest pose + VRM4U's spring bone node, driven the same way VRM4U's own
// UVrmAnimInstanceCopy drives it (bCallByAnimInstance, 3x20 warm-up steps).
UCLASS(Transient)
class UVrmReproAnimInstance : public UAnimInstance
{
    GENERATED_BODY()

public:
    UVrmReproAnimInstance(const FObjectInitializer& ObjectInitializer);

    UPROPERTY(Transient)
    TObjectPtr<UVrmMetaObject> Meta;

    float SpringDeltaSeconds = 0.f;

    // Isolate the spring solver: no gravity, wind or colliders, so an unmoving
    // character must keep every spring chain in its authored rest pose.
    bool bNoGravityNoWind = true;  // also disables VRM colliders

protected:
    virtual FAnimInstanceProxy* CreateAnimInstanceProxy() override;
    virtual void NativeUpdateAnimation(float DeltaSeconds) override;
};
