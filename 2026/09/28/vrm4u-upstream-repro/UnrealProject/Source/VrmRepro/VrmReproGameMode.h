#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "VrmReproGameMode.generated.h"

UCLASS()
class AVrmReproGameMode : public AGameModeBase
{
    GENERATED_BODY()

protected:
    virtual void BeginPlay() override;
};
