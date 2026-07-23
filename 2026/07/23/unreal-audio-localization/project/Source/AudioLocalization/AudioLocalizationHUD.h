// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/HUD.h"
#include "AudioLocalizationHUD.generated.h"

class AAudioLocalizationExperiment;

UCLASS()
class AUDIOLOCALIZATION_API AAudioLocalizationHUD : public AHUD
{
	GENERATED_BODY()

public:
	virtual void DrawHUD() override;

private:
	AAudioLocalizationExperiment* FindExperiment();
	void DrawWaveformPanel(
		const FString& Label,
		const TArray<float>& Samples,
		float Rms,
		const FLinearColor& Color,
		float X,
		float Y,
		float Width,
		float Height);

	TWeakObjectPtr<AAudioLocalizationExperiment> Experiment;
	float WaveformFullScaleAmplitude = 0.05f;
	bool bLoggedReady = false;
};
