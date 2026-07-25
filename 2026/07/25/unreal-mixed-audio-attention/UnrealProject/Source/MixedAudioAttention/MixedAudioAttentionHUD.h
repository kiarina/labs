#pragma once

#include "CoreMinimal.h"
#include "GameFramework/HUD.h"
#include "MixedAudioAttentionHUD.generated.h"

class AMixedAudioAttentionExperiment;
class UTexture2D;

UCLASS()
class MIXEDAUDIOATTENTION_API AMixedAudioAttentionHUD : public AHUD
{
	GENERATED_BODY()
public:
	virtual void DrawHUD() override;
private:
	AMixedAudioAttentionExperiment* FindExperiment();
	void EnsureTextures(int32 Width, int32 Height);
	void UpdateSpectrogramTexture(UTexture2D* Texture, const TArray<float>& Values, const TArray<float>& Mask, int32 Columns, int32 Bins, bool bLeft);
	void DrawWaveform(const TArray<float>& Samples, const TArray<float>* Overlay, const FLinearColor& Color, float X, float Y, float Width, float Height, float FullScale, int32 Onset = INDEX_NONE);
	void DrawTexturePanel(UTexture2D* Texture, float X, float Y, float Width, float Height);
	TWeakObjectPtr<AMixedAudioAttentionExperiment> Experiment;
	UPROPERTY(Transient) TObjectPtr<UTexture2D> LeftTexture;
	UPROPERTY(Transient) TObjectPtr<UTexture2D> RightTexture;
	int64 LastTextureFrame = -1;
	bool bDetailedView = false;
};
