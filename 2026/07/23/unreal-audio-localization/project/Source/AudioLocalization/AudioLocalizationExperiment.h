// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "AudioLocalizationExperiment.generated.h"

class UAudioComponent;
class UCapsuleComponent;
class UMaterialInstanceDynamic;
class UPrimitiveComponent;
class USceneComponent;
class UStaticMeshComponent;
class FAudioLocalizationSubmixListener;

struct FAudioLocalizationExpectedEvent
{
	int32 SourceIndex = INDEX_NONE;
	int64 EmittedAfterFrame = 0;
	float AzimuthDegrees = 0.0f;
	FVector ListenerLocation = FVector::ZeroVector;
	FString GroundTruth = TEXT("Unknown");
	bool bMatched = false;
};

struct FAudioLocalizationVisualizationSnapshot
{
	TArray<float> LeftWaveform;
	TArray<float> RightWaveform;
	FVector ListenerLocation = FVector::ZeroVector;
	FString Prediction = TEXT("Unknown");
	float LeftRms = 0.0f;
	float RightRms = 0.0f;
	float IldDb = 0.0f;
	float Correlation = 0.0f;
	int32 LagSamples = 0;
	int32 ActiveSourceCount = 0;
	bool bStreamReady = false;
};

namespace AudioLocalizationSignal
{
	struct FEstimate
	{
		int32 LagSamples = 0;
		float LagMilliseconds = 0.0f;
		float InterauralLevelDifferenceDb = 0.0f;
		float Correlation = 0.0f;
		FString Prediction = TEXT("Unknown");
	};

	AUDIOLOCALIZATION_API TArray<float> GenerateChirp(
		int32 SampleRate,
		float DurationSeconds,
		float StartFrequencyHz,
		float EndFrequencyHz);

	AUDIOLOCALIZATION_API void SynthesizeVirtualMicrophones(
		const TArray<float>& SourceWaveform,
		int32 SampleRate,
		float SpeedOfSoundMetersPerSecond,
		const FVector& SourceLocationCm,
		const FVector& LeftEarLocationCm,
		const FVector& RightEarLocationCm,
		TArray<float>& OutLeft,
		TArray<float>& OutRight,
		float& OutLeftDistanceMeters,
		float& OutRightDistanceMeters);

	AUDIOLOCALIZATION_API FEstimate EstimateSide(
		const TArray<float>& Left,
		const TArray<float>& Right,
		int32 SampleRate,
		int32 MaximumLagSamples,
		float MinimumCorrelation);
}

UCLASS()
class AUDIOLOCALIZATION_API AAudioLocalizationPulseSource : public AActor
{
	GENERATED_BODY()

public:
	AAudioLocalizationPulseSource();

	void EmitPulse(const TArray<float>& Waveform, int32 SampleRate);
	void InitializeInteractive(const TArray<float>& Waveform, int32 SampleRate);
	void SetInteractiveEnabled(bool bEnabled);
	bool IsRepeating() const { return bRepeating; }

protected:
	virtual void BeginPlay() override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

private:
	UFUNCTION()
	void OnActivationTriggerBeginOverlap(
		UPrimitiveComponent* OverlappedComponent,
		AActor* OtherActor,
		UPrimitiveComponent* OtherComponent,
		int32 OtherBodyIndex,
		bool bFromSweep,
		const FHitResult& SweepResult);

	void EmitInteractivePulse();
	void SetRepeating(bool bEnabled);
	void UpdateVisualizerState();

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<USceneComponent> SceneRoot;

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<UStaticMeshComponent> Visualizer;

	UPROPERTY(Transient)
	TObjectPtr<UMaterialInstanceDynamic> VisualizerMaterial;

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<UAudioComponent> AudioComponent;

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<UCapsuleComponent> ActivationTrigger;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Interactive")
	float RepeatIntervalSeconds = 0.75f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Interactive")
	float ToggleCooldownSeconds = 0.50f;

	TArray<float> InteractiveWaveform;
	FTimerHandle RepeatTimer;
	double LastToggleSeconds = -DBL_MAX;
	int32 InteractiveSampleRate = 0;
	bool bInteractiveEnabled = false;
	bool bRepeating = false;
};

UCLASS()
class AUDIOLOCALIZATION_API AAudioLocalizationExperiment : public AActor
{
	GENERATED_BODY()

public:
	AAudioLocalizationExperiment();
	void GetVisualizationSnapshot(FAudioLocalizationVisualizationSnapshot& OutSnapshot) const;

protected:
	virtual void BeginPlay() override;
	virtual void Tick(float DeltaSeconds) override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

private:
	bool RegisterSubmixListener();
	void UnregisterSubmixListener();
	void RunNextTrial();
	void CompleteRenderedTrial();
	void FinishExperiment();
	void EmitNextContinuousEvent();
	void AnalyzeContinuousStream();
	void FinishContinuousExperiment();
	void UpdateVisualizationSnapshot();
	bool GetEarRig(FVector& OutCenter, FVector& OutForward, FVector& OutRight);

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<USceneComponent> SceneRoot;

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<UStaticMeshComponent> LeftMicrophone;

	UPROPERTY(VisibleAnywhere, Category="Audio Localization")
	TObjectPtr<UStaticMeshComponent> RightMicrophone;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Signal")
	int32 SampleRate = 48000;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Signal")
	float ChirpDurationSeconds = 0.020f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Signal")
	float StartFrequencyHz = 500.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Signal")
	float EndFrequencyHz = 4000.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Geometry")
	float EarSpacingCentimeters = 18.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Geometry")
	float SpeedOfSoundMetersPerSecond = 343.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	int32 TrialsPerSource = 5;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	float InitialDelaySeconds = 1.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	float PulseIntervalSeconds = 0.25f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	float CaptureDurationSeconds = 0.10f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	float AmbiguousAngleDegrees = 15.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Experiment")
	bool bForceAudioWhenUnfocused = true;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	bool bContinuousStreaming = true;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Interactive")
	bool bInteractiveMode = true;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Interactive")
	float VisualizationHistorySeconds = 0.20f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Interactive")
	float VisualizationRefreshSeconds = 0.05f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float StreamBufferSeconds = 5.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float AnalysisWindowMilliseconds = 30.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float AnalysisHopMilliseconds = 15.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float OnsetMinimumRms = 0.001f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float OnsetRiseRatio = 3.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Streaming")
	float ContinuousEventIntervalSeconds = 0.75f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Validation")
	bool bApplyValidationAvatarMotion = false;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Validation")
	float ValidationAvatarForwardOffsetCentimeters = 100.0f;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Validation")
	bool bApplyValidationInteractiveContact = false;

	UPROPERTY(EditAnywhere, Category="Audio Localization|Validation")
	float ValidationInteractiveContactDelaySeconds = 1.0f;

	TArray<TObjectPtr<AAudioLocalizationPulseSource>> Sources;
	TArray<float> SourceWaveform;
	TArray<TSharedPtr<class FJsonValue>> TrialJson;
	TSharedPtr<FAudioLocalizationSubmixListener, ESPMode::ThreadSafe> SubmixListener;
	FTimerHandle TrialTimer;
	FTimerHandle AnalysisTimer;
	FString ActiveSpatializationPlugin = TEXT("Unavailable");
	FString PendingGroundTruth = TEXT("Unknown");
	float PendingAzimuthDegrees = 0.0f;
	bool bPendingAmbiguous = true;
	bool bAppHadFocusAtBegin = false;
	bool bAppHasFocusAfterOverride = false;
	bool bPreviousUseVrFocus = false;
	bool bPreviousHasVrFocus = false;
	bool bPreviousPauseOnLossOfFocus = false;
	float PreviousAppVolumeMultiplier = 1.0f;
	int32 CurrentSourceIndex = 0;
	int32 CurrentRepetition = 0;
	int32 CorrectTrials = 0;
	int32 EvaluatedTrials = 0;
	int32 UnknownTrials = 0;
	TArray<FAudioLocalizationExpectedEvent> ExpectedContinuousEvents;
	TArray<TSharedPtr<class FJsonValue>> ContinuousDetectionJson;
	int32 ContinuousSourceIndex = 0;
	int64 NextAnalysisFrame = 0;
	int64 LastDetectionFrame = MIN_int64;
	float NoiseFloorRms = 1.0e-6f;
	float MaximumObservedWindowRms = 0.0f;
	int32 ContinuousCorrectDetections = 0;
	int32 ContinuousUnknownDetections = 0;
	int32 ContinuousFalsePositives = 0;
	bool bContinuousFinishing = false;
	bool bContinuousActive = false;
	bool bValidationAvatarMotionApplied = false;
	bool bValidationInteractiveContactApplied = false;
	int32 ValidationInteractiveContactPhase = 0;
	double NextContinuousActionSeconds = 0.0;
	double NextVisualizationUpdateSeconds = 0.0;
	double InteractiveStartSeconds = 0.0;
	double ValidationInteractiveContactPhaseSeconds = 0.0;
	FVector ValidationInteractiveOriginalPawnLocation = FVector::ZeroVector;
	FAudioLocalizationVisualizationSnapshot VisualizationSnapshot;
};
