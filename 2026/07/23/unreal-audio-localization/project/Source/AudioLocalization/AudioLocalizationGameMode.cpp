// Copyright Epic Games, Inc. All Rights Reserved.

#include "AudioLocalizationGameMode.h"
#include "AudioLocalizationHUD.h"

AAudioLocalizationGameMode::AAudioLocalizationGameMode()
{
	HUDClass = AAudioLocalizationHUD::StaticClass();
}
