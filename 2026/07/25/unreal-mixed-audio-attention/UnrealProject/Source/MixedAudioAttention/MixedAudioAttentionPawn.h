#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Pawn.h"
#include "MixedAudioAttentionPawn.generated.h"

class UCameraComponent;
class UCapsuleComponent;
class USpringArmComponent;
class UStaticMeshComponent;

UCLASS()
class MIXEDAUDIOATTENTION_API AMixedAudioAttentionPawn : public APawn
{
	GENERATED_BODY()

public:
	AMixedAudioAttentionPawn();
	virtual void Tick(float DeltaSeconds) override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
	virtual void SetupPlayerInputComponent(UInputComponent* PlayerInputComponent) override;
	FVector GetHeadLocation() const;

private:
	void Turn(float Value);
	void LookUp(float Value);
	void UpdateAudioListener();

	UPROPERTY() TObjectPtr<UCapsuleComponent> Capsule;
	UPROPERTY() TObjectPtr<UStaticMeshComponent> Body;
	UPROPERTY() TObjectPtr<UStaticMeshComponent> Head;
	UPROPERTY() TObjectPtr<UStaticMeshComponent> LeftEar;
	UPROPERTY() TObjectPtr<UStaticMeshComponent> RightEar;
	UPROPERTY() TObjectPtr<USpringArmComponent> CameraBoom;
	UPROPERTY() TObjectPtr<UCameraComponent> Camera;
	float MoveSpeed = 500.0f;
};
