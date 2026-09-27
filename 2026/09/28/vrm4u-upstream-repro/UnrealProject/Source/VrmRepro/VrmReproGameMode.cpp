#include "VrmReproGameMode.h"

#include "Engine/World.h"
#include "VrmReproDriver.h"

void AVrmReproGameMode::BeginPlay()
{
    Super::BeginPlay();
    if (FParse::Param(FCommandLine::Get(), TEXT("VrmRepro")))
    {
        GetWorld()->SpawnActor<AVrmReproDriver>();
    }
}
