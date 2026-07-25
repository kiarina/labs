#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "MixedAudioAttentionSignal.h"
#include "MixedAudioAttentionExperiment.generated.h"

class UAudioComponent;
class UMaterialInstanceDynamic;
class USceneComponent;
class USphereComponent;
class UStaticMeshComponent;
class USoundWaveProcedural;
class UTextRenderComponent;
class FMixedAudioSubmixListener;
class FJsonValue;

enum class EMixedAudioSourceKind : uint8
{
	Ambient,
	Burst,
};

UCLASS()
class MIXEDAUDIOATTENTION_API AMixedAudioSource : public AActor
{
	GENERATED_BODY()
public:
	AMixedAudioSource();
	virtual void BeginPlay() override;
	virtual void Tick(float DeltaSeconds) override;
	void ConfigureContinuous(int32 Seed, float Volume, bool bHighBand, float DurationSeconds);
	void ConfigureBurst(bool bInitiallyEnabled);
	bool Emit(const TArray<float>& Samples, int32 SampleRate, float Volume);
	bool IsSourceEnabled() const { return bSourceEnabled; }
	void StopSource();
private:
	UFUNCTION()
	void OnActivationBeginOverlap(
		UPrimitiveComponent* OverlappedComponent,
		AActor* OtherActor,
		UPrimitiveComponent* OtherComponent,
		int32 OtherBodyIndex,
		bool bFromSweep,
		const FHitResult& SweepResult);
	void SetSourceEnabled(bool bEnabled);
	void UpdateVisualizerState();
	UPROPERTY() TObjectPtr<USceneComponent> SceneRoot;
	UPROPERTY() TObjectPtr<UStaticMeshComponent> Visualizer;
	UPROPERTY() TObjectPtr<USphereComponent> ActivationTrigger;
	UPROPERTY() TObjectPtr<UTextRenderComponent> Label;
	UPROPERTY() TObjectPtr<UAudioComponent> AudioComponent;
	UPROPERTY(Transient) TObjectPtr<UMaterialInstanceDynamic> VisualizerMaterial;
	UPROPERTY(Transient) TObjectPtr<USoundWaveProcedural> ProceduralWave;
	EMixedAudioSourceKind Kind = EMixedAudioSourceKind::Burst;
	double LastToggleSeconds = -DBL_MAX;
	bool bSourceEnabled = false;
};

UCLASS()
class MIXEDAUDIOATTENTION_API AMixedAudioAttentionExperiment : public AActor
{
	GENERATED_BODY()
public:
	AMixedAudioAttentionExperiment();
	virtual void BeginPlay() override;
	virtual void Tick(float DeltaSeconds) override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
	void GetSnapshots(FMixedAudioLiveSnapshot& OutLive, FMixedAudioEventSnapshot& OutEvent) const;
	int32 GetActiveSourceCount() const;
private:
	bool RegisterSubmixListener();
	void PullCapturedAudio();
	void EmitDemoEvent();
	void SaveEvent(const FMixedAudioEventSnapshot& Event);
	void SaveSummary();
	UPROPERTY() TObjectPtr<USceneComponent> SceneRoot;
	UPROPERTY() TArray<TObjectPtr<AMixedAudioSource>> Sources;
	TSharedPtr<FMixedAudioSubmixListener, ESPMode::ThreadSafe> SubmixListener;
	TUniquePtr<FMixedAudioAnalyzer> Analyzer;
	FTimerHandle EventTimer;
	int64 NextReadFrame = 0;
	int64 LastSavedDetectionFrame = MIN_int64;
	int32 EventIndex = 0;
	int32 SavedEventCount = 0;
	TArray<TSharedPtr<FJsonValue>> EventRecords;
	int64 NextDiagnosticFrame = 0;
	float PreviousVolumeMultiplier = 1.0f;
	bool bPreviousUseVrFocus = false;
	bool bPreviousHasVrFocus = false;
	bool bPreviousPauseOnLossOfFocus = false;
	bool bFullExperiment = false;
};
