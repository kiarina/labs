#include "MixedAudioAttentionGameMode.h"

#include "MixedAudioAttentionExperiment.h"
#include "MixedAudioAttentionHUD.h"
#include "MixedAudioAttentionPawn.h"
#include "Kismet/GameplayStatics.h"

AMixedAudioAttentionGameMode::AMixedAudioAttentionGameMode()
{
	HUDClass = AMixedAudioAttentionHUD::StaticClass();
	DefaultPawnClass = AMixedAudioAttentionPawn::StaticClass();
}

void AMixedAudioAttentionGameMode::BeginPlay()
{
	Super::BeginPlay();
	if (APlayerController* PC = UGameplayStatics::GetPlayerController(this, 0))
	{
		if (!PC->GetPawn())
		{
			AMixedAudioAttentionPawn* Pawn = GetWorld()->SpawnActor<AMixedAudioAttentionPawn>(FVector(0.0f, 0.0f, 100.0f), FRotator::ZeroRotator);
			PC->Possess(Pawn);
		}
		else PC->GetPawn()->SetActorLocation(FVector(0.0f, 0.0f, 100.0f));
	}
	GetWorld()->SpawnActor<AMixedAudioAttentionExperiment>(FVector::ZeroVector, FRotator::ZeroRotator);
}
