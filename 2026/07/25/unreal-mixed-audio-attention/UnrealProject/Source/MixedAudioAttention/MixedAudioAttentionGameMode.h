#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "MixedAudioAttentionGameMode.generated.h"

UCLASS()
class MIXEDAUDIOATTENTION_API AMixedAudioAttentionGameMode : public AGameModeBase
{
	GENERATED_BODY()
public:
	AMixedAudioAttentionGameMode();
	virtual void BeginPlay() override;
};
