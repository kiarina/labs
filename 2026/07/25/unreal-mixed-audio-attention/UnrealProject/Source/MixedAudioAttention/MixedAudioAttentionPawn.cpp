#include "MixedAudioAttentionPawn.h"

#include "Camera/CameraComponent.h"
#include "Components/CapsuleComponent.h"
#include "Components/InputComponent.h"
#include "Components/StaticMeshComponent.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/SpringArmComponent.h"
#include "InputCoreTypes.h"
#include "UObject/ConstructorHelpers.h"

AMixedAudioAttentionPawn::AMixedAudioAttentionPawn()
{
	PrimaryActorTick.bCanEverTick = true;
	AutoPossessPlayer = EAutoReceiveInput::Player0;

	Capsule = CreateDefaultSubobject<UCapsuleComponent>(TEXT("Capsule"));
	Capsule->InitCapsuleSize(34.0f, 88.0f);
	Capsule->SetCollisionProfileName(TEXT("Pawn"));
	SetRootComponent(Capsule);

	static ConstructorHelpers::FObjectFinder<UStaticMesh> CubeMesh(TEXT("/Engine/BasicShapes/Cube.Cube"));
	auto ConfigureBlock = [](UStaticMeshComponent* Component, const FVector& Location, const FVector& Scale)
	{
		Component->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		Component->SetRelativeLocation(Location);
		Component->SetRelativeScale3D(Scale);
		if (CubeMesh.Succeeded()) Component->SetStaticMesh(CubeMesh.Object);
	};

	Body = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("Body")); Body->SetupAttachment(Capsule);
	ConfigureBlock(Body, FVector(0.0f, 0.0f, -12.0f), FVector(0.42f, 0.28f, 0.62f));
	Head = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("Head")); Head->SetupAttachment(Capsule);
	ConfigureBlock(Head, FVector(0.0f, 0.0f, 72.0f), FVector(0.30f));
	LeftEar = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("LeftEar")); LeftEar->SetupAttachment(Head);
	ConfigureBlock(LeftEar, FVector(0.0f, -58.0f, 0.0f), FVector(0.08f, 0.06f, 0.12f));
	RightEar = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("RightEar")); RightEar->SetupAttachment(Head);
	ConfigureBlock(RightEar, FVector(0.0f, 58.0f, 0.0f), FVector(0.08f, 0.06f, 0.12f));

	CameraBoom = CreateDefaultSubobject<USpringArmComponent>(TEXT("CameraBoom"));
	CameraBoom->SetupAttachment(Head); CameraBoom->TargetArmLength = 420.0f;
	CameraBoom->SetRelativeLocation(FVector(0.0f, 0.0f, 35.0f)); CameraBoom->bUsePawnControlRotation = true;
	CameraBoom->bDoCollisionTest = false;
	Camera = CreateDefaultSubobject<UCameraComponent>(TEXT("Camera")); Camera->SetupAttachment(CameraBoom);
	Camera->bUsePawnControlRotation = false;

	bUseControllerRotationYaw = false;
}

void AMixedAudioAttentionPawn::SetupPlayerInputComponent(UInputComponent* PlayerInputComponent)
{
	Super::SetupPlayerInputComponent(PlayerInputComponent);
}

void AMixedAudioAttentionPawn::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (APlayerController* PC = Cast<APlayerController>(Controller))
	{
		const float Forward = (PC->IsInputKeyDown(EKeys::W) ? 1.0f : 0.0f) - (PC->IsInputKeyDown(EKeys::S) ? 1.0f : 0.0f);
		const float Right = (PC->IsInputKeyDown(EKeys::D) ? 1.0f : 0.0f) - (PC->IsInputKeyDown(EKeys::A) ? 1.0f : 0.0f);
		const FRotator Yaw(0.0f, PC->GetControlRotation().Yaw, 0.0f);
		const FVector Input = (FRotationMatrix(Yaw).GetUnitAxis(EAxis::X) * Forward + FRotationMatrix(Yaw).GetUnitAxis(EAxis::Y) * Right).GetClampedToMaxSize(1.0f);
		if (!Input.IsNearlyZero()) AddActorWorldOffset(Input * MoveSpeed * DeltaSeconds, true);
		float MouseX = 0.0f, MouseY = 0.0f; PC->GetInputMouseDelta(MouseX, MouseY);
		Turn(MouseX * 0.07f); LookUp(MouseY * -0.07f);
		SetActorRotation(FRotator(0.0f, PC->GetControlRotation().Yaw, 0.0f));
	}
	UpdateAudioListener();
}

void AMixedAudioAttentionPawn::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	if (APlayerController* PC = Cast<APlayerController>(Controller)) PC->ClearAudioListenerOverride();
	Super::EndPlay(EndPlayReason);
}

void AMixedAudioAttentionPawn::Turn(float Value) { AddControllerYawInput(Value); }
void AMixedAudioAttentionPawn::LookUp(float Value) { AddControllerPitchInput(Value); }

FVector AMixedAudioAttentionPawn::GetHeadLocation() const
{
	return Head ? Head->GetComponentLocation() : GetActorLocation();
}

void AMixedAudioAttentionPawn::UpdateAudioListener()
{
	APlayerController* PC = Cast<APlayerController>(Controller);
	if (!PC) return;
	const FRotator ViewRotation = PC->GetControlRotation();
	PC->SetAudioListenerOverride(nullptr, GetHeadLocation(), FRotator(0.0f, ViewRotation.Yaw, 0.0f));
}
