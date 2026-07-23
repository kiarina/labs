// Copyright Epic Games, Inc. All Rights Reserved.

#include "AudioLocalizationExperiment.h"

#include "AudioLocalization.h"
#include "AudioDevice.h"
#include "Components/AudioComponent.h"
#include "Components/CapsuleComponent.h"
#include "Components/SceneComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/World.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerController.h"
#include "Dom/JsonObject.h"
#include "HAL/FileManager.h"
#include "ISubmixBufferListener.h"
#include "Misc/ScopeLock.h"
#include "Misc/EngineVersion.h"
#include "Misc/App.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "Kismet/GameplayStatics.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Materials/MaterialInterface.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Sound/SoundWaveProcedural.h"
#include "Sound/SoundAttenuation.h"
#include "TimerManager.h"
#include "UObject/ConstructorHelpers.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"
#endif

namespace
{
	constexpr float SmallEnergy = 1.0e-12f;

	void AddFractionallyDelayedSignal(
		const TArray<float>& Input,
		float DelaySamples,
		float Gain,
		TArray<float>& Output)
	{
		const int32 WholeDelay = FMath::FloorToInt(DelaySamples);
		const float Fraction = DelaySamples - static_cast<float>(WholeDelay);

		for (int32 Index = 0; Index < Input.Num(); ++Index)
		{
			const int32 OutputIndex = Index + WholeDelay;
			const float Value = Input[Index] * Gain;
			Output[OutputIndex] += Value * (1.0f - Fraction);
			Output[OutputIndex + 1] += Value * Fraction;
		}
	}

	FString SideFromAzimuth(float AzimuthDegrees)
	{
		return AzimuthDegrees < 0.0f ? TEXT("Left") : TEXT("Right");
	}

	bool ExtractActiveStereo(
		const TArray<float>& Interleaved,
		int32 NumChannels,
		TArray<float>& OutLeft,
		TArray<float>& OutRight,
		int32& OutRawFrames)
	{
		OutLeft.Reset();
		OutRight.Reset();
		OutRawFrames = NumChannels > 0 ? Interleaved.Num() / NumChannels : 0;
		if (NumChannels < 2 || OutRawFrames == 0)
		{
			return false;
		}

		float Peak = 0.0f;
		for (int32 Frame = 0; Frame < OutRawFrames; ++Frame)
		{
			const int32 Offset = Frame * NumChannels;
			Peak = FMath::Max(Peak, FMath::Abs(Interleaved[Offset]));
			Peak = FMath::Max(Peak, FMath::Abs(Interleaved[Offset + 1]));
		}
		if (Peak < 1.0e-6f)
		{
			return false;
		}

		const float ActivityThreshold = FMath::Max(1.0e-5f, Peak * 0.01f);
		int32 FirstActive = INDEX_NONE;
		int32 LastActive = INDEX_NONE;
		for (int32 Frame = 0; Frame < OutRawFrames; ++Frame)
		{
			const int32 Offset = Frame * NumChannels;
			if (FMath::Max(
				FMath::Abs(Interleaved[Offset]),
				FMath::Abs(Interleaved[Offset + 1])) >= ActivityThreshold)
			{
				FirstActive = FirstActive == INDEX_NONE ? Frame : FirstActive;
				LastActive = Frame;
			}
		}
		if (FirstActive == INDEX_NONE)
		{
			return false;
		}

		constexpr int32 GuardFrames = 64;
		FirstActive = FMath::Max(0, FirstActive - GuardFrames);
		LastActive = FMath::Min(OutRawFrames - 1, LastActive + GuardFrames);
		const int32 ActiveFrames = LastActive - FirstActive + 1;
		OutLeft.SetNumUninitialized(ActiveFrames);
		OutRight.SetNumUninitialized(ActiveFrames);
		for (int32 Frame = 0; Frame < ActiveFrames; ++Frame)
		{
			const int32 Offset = (FirstActive + Frame) * NumChannels;
			OutLeft[Frame] = Interleaved[Offset];
			OutRight[Frame] = Interleaved[Offset + 1];
		}
		return true;
	}

	float RootMeanSquare(const TArray<float>& Samples)
	{
		if (Samples.IsEmpty())
		{
			return 0.0f;
		}
		double Energy = 0.0;
		for (float Sample : Samples)
		{
			Energy += static_cast<double>(Sample) * Sample;
		}
		return FMath::Sqrt(static_cast<float>(Energy / Samples.Num()));
	}
}

class FAudioLocalizationSubmixListener final : public ISubmixBufferListener
{
public:
	void StartStreaming(float BufferSeconds)
	{
		FScopeLock Lock(&Mutex);
		constexpr int32 MaximumExpectedChannels = 8;
		constexpr int32 MaximumExpectedSampleRate = 48000;
		RingSamples.SetNumZeroed(FMath::CeilToInt(BufferSeconds *
			MaximumExpectedSampleRate * MaximumExpectedChannels));
		NumChannels = 0;
		SampleRate = 0;
		TotalFramesWritten = 0;
		bFormatChanged = false;
		bStreaming = true;
	}

	void StopStreaming()
	{
		FScopeLock Lock(&Mutex);
		bStreaming = false;
	}

	bool GetStreamState(int32& OutNumChannels, int32& OutSampleRate, int64& OutTotalFrames)
	{
		FScopeLock Lock(&Mutex);
		OutNumChannels = NumChannels;
		OutSampleRate = SampleRate;
		OutTotalFrames = TotalFramesWritten;
		return bStreaming && NumChannels >= 2 && SampleRate > 0;
	}

	bool ReadStereoFrames(
		int64 StartFrame,
		int32 NumFrames,
		TArray<float>& OutLeft,
		TArray<float>& OutRight)
	{
		FScopeLock Lock(&Mutex);
		if (!bStreaming || NumChannels < 2 || SampleRate <= 0 || RingSamples.IsEmpty())
		{
			return false;
		}
		const int64 CapacityFrames = RingSamples.Num() / NumChannels;
		const int64 EarliestFrame = FMath::Max<int64>(0, TotalFramesWritten - CapacityFrames);
		if (StartFrame < EarliestFrame || StartFrame + NumFrames > TotalFramesWritten)
		{
			return false;
		}

		OutLeft.SetNumUninitialized(NumFrames);
		OutRight.SetNumUninitialized(NumFrames);
		for (int32 Frame = 0; Frame < NumFrames; ++Frame)
		{
			const int64 RingFrame = (StartFrame + Frame) % CapacityFrames;
			const int64 Offset = RingFrame * NumChannels;
			OutLeft[Frame] = RingSamples[Offset];
			OutRight[Frame] = RingSamples[Offset + 1];
		}
		return true;
	}

	void BeginCapture()
	{
		FScopeLock Lock(&Mutex);
		CapturedSamples.Reset();
		NumChannels = 0;
		SampleRate = 0;
		bFormatChanged = false;
		bCapturing = true;
	}

	bool EndCapture(
		TArray<float>& OutSamples,
		int32& OutNumChannels,
		int32& OutSampleRate,
		bool& OutFormatChanged)
	{
		FScopeLock Lock(&Mutex);
		bCapturing = false;
		OutSamples = MoveTemp(CapturedSamples);
		OutNumChannels = NumChannels;
		OutSampleRate = SampleRate;
		OutFormatChanged = bFormatChanged;
		return !OutSamples.IsEmpty() && OutNumChannels > 0 && OutSampleRate > 0;
	}

	virtual void OnNewSubmixBuffer(
		const USoundSubmix* OwningSubmix,
		float* AudioData,
		int32 NumSamples,
		int32 InNumChannels,
		const int32 InSampleRate,
		double AudioClock) override
	{
		FScopeLock Lock(&Mutex);
		if (AudioData == nullptr || NumSamples <= 0 || InNumChannels <= 0)
		{
			return;
		}
		if (NumChannels == 0)
		{
			NumChannels = InNumChannels;
			SampleRate = InSampleRate;
		}
		else if (NumChannels != InNumChannels || SampleRate != InSampleRate)
		{
			bFormatChanged = true;
			return;
		}

		if (bStreaming && !RingSamples.IsEmpty())
		{
			const int32 NumFrames = NumSamples / InNumChannels;
			const int64 CapacityFrames = RingSamples.Num() / InNumChannels;
			for (int32 Frame = 0; Frame < NumFrames; ++Frame)
			{
				const int64 RingFrame = (TotalFramesWritten + Frame) % CapacityFrames;
				const int64 DestinationOffset = RingFrame * InNumChannels;
				const int32 SourceOffset = Frame * InNumChannels;
				for (int32 Channel = 0; Channel < InNumChannels; ++Channel)
				{
					RingSamples[DestinationOffset + Channel] = AudioData[SourceOffset + Channel];
				}
			}
			TotalFramesWritten += NumFrames;
		}
		else if (bCapturing)
		{
			CapturedSamples.Append(AudioData, NumSamples);
		}
	}

	virtual const FString& GetListenerName() const override
	{
		static const FString Name = TEXT("AudioLocalizationRenderedStereoCapture");
		return Name;
	}

private:
	FCriticalSection Mutex;
	TArray<float> CapturedSamples;
	TArray<float> RingSamples;
	int32 NumChannels = 0;
	int32 SampleRate = 0;
	int64 TotalFramesWritten = 0;
	bool bCapturing = false;
	bool bStreaming = false;
	bool bFormatChanged = false;
};

TArray<float> AudioLocalizationSignal::GenerateChirp(
	int32 SampleRate,
	float DurationSeconds,
	float StartFrequencyHz,
	float EndFrequencyHz)
{
	const int32 NumSamples = FMath::Max(2, FMath::RoundToInt(SampleRate * DurationSeconds));
	TArray<float> Waveform;
	Waveform.SetNumUninitialized(NumSamples);
	const float FrequencySlope = (EndFrequencyHz - StartFrequencyHz) / DurationSeconds;

	for (int32 Index = 0; Index < NumSamples; ++Index)
	{
		const float Time = static_cast<float>(Index) / static_cast<float>(SampleRate);
		const float Phase = 2.0f * UE_PI *
			(StartFrequencyHz * Time + 0.5f * FrequencySlope * Time * Time);
		const float Hann = 0.5f - 0.5f * FMath::Cos(
			2.0f * UE_PI * static_cast<float>(Index) / static_cast<float>(NumSamples - 1));
		Waveform[Index] = 0.8f * Hann * FMath::Sin(Phase);
	}

	return Waveform;
}

void AudioLocalizationSignal::SynthesizeVirtualMicrophones(
	const TArray<float>& SourceWaveform,
	int32 SampleRate,
	float SpeedOfSoundMetersPerSecond,
	const FVector& SourceLocationCm,
	const FVector& LeftEarLocationCm,
	const FVector& RightEarLocationCm,
	TArray<float>& OutLeft,
	TArray<float>& OutRight,
	float& OutLeftDistanceMeters,
	float& OutRightDistanceMeters)
{
	OutLeftDistanceMeters = FVector::Distance(SourceLocationCm, LeftEarLocationCm) / 100.0f;
	OutRightDistanceMeters = FVector::Distance(SourceLocationCm, RightEarLocationCm) / 100.0f;

	const float LeftDelaySamples = OutLeftDistanceMeters / SpeedOfSoundMetersPerSecond * SampleRate;
	const float RightDelaySamples = OutRightDistanceMeters / SpeedOfSoundMetersPerSecond * SampleRate;
	const int32 OutputSamples = SourceWaveform.Num() +
		FMath::CeilToInt(FMath::Max(LeftDelaySamples, RightDelaySamples)) + 2;

	OutLeft.Init(0.0f, OutputSamples);
	OutRight.Init(0.0f, OutputSamples);

	const float LeftGain = 1.0f / FMath::Max(OutLeftDistanceMeters, 0.25f);
	const float RightGain = 1.0f / FMath::Max(OutRightDistanceMeters, 0.25f);
	AddFractionallyDelayedSignal(SourceWaveform, LeftDelaySamples, LeftGain, OutLeft);
	AddFractionallyDelayedSignal(SourceWaveform, RightDelaySamples, RightGain, OutRight);
}

AudioLocalizationSignal::FEstimate AudioLocalizationSignal::EstimateSide(
	const TArray<float>& Left,
	const TArray<float>& Right,
	int32 SampleRate,
	int32 MaximumLagSamples,
	float MinimumCorrelation)
{
	FEstimate Estimate;
	if (Left.IsEmpty() || Right.IsEmpty() || SampleRate <= 0)
	{
		return Estimate;
	}

	float LeftEnergy = 0.0f;
	float RightEnergy = 0.0f;
	for (float Value : Left)
	{
		LeftEnergy += Value * Value;
	}
	for (float Value : Right)
	{
		RightEnergy += Value * Value;
	}
	Estimate.InterauralLevelDifferenceDb = 10.0f * FMath::LogX(
		10.0f,
		(LeftEnergy + SmallEnergy) / (RightEnergy + SmallEnergy));

	float BestCorrelation = -1.0f;
	int32 BestLag = 0;
	for (int32 Lag = -MaximumLagSamples; Lag <= MaximumLagSamples; ++Lag)
	{
		float Cross = 0.0f;
		float LagLeftEnergy = 0.0f;
		float LagRightEnergy = 0.0f;
		for (int32 LeftIndex = 0; LeftIndex < Left.Num(); ++LeftIndex)
		{
			const int32 RightIndex = LeftIndex + Lag;
			if (!Right.IsValidIndex(RightIndex))
			{
				continue;
			}
			const float LeftValue = Left[LeftIndex];
			const float RightValue = Right[RightIndex];
			Cross += LeftValue * RightValue;
			LagLeftEnergy += LeftValue * LeftValue;
			LagRightEnergy += RightValue * RightValue;
		}

		const float Denominator = FMath::Sqrt(LagLeftEnergy * LagRightEnergy) + SmallEnergy;
		const float Correlation = Cross / Denominator;
		if (Correlation > BestCorrelation)
		{
			BestCorrelation = Correlation;
			BestLag = Lag;
		}
	}

	Estimate.LagSamples = BestLag;
	Estimate.LagMilliseconds = 1000.0f * static_cast<float>(BestLag) / SampleRate;
	Estimate.Correlation = BestCorrelation;

	if (BestCorrelation >= MinimumCorrelation && BestLag > 0)
	{
		Estimate.Prediction = TEXT("Left");
	}
	else if (BestCorrelation >= MinimumCorrelation && BestLag < 0)
	{
		Estimate.Prediction = TEXT("Right");
	}
	else if (FMath::Abs(Estimate.InterauralLevelDifferenceDb) >= 0.10f)
	{
		Estimate.Prediction = Estimate.InterauralLevelDifferenceDb > 0.0f
			? TEXT("Left")
			: TEXT("Right");
	}

	return Estimate;
}

AAudioLocalizationPulseSource::AAudioLocalizationPulseSource()
{
	PrimaryActorTick.bCanEverTick = false;

	SceneRoot = CreateDefaultSubobject<USceneComponent>(TEXT("SceneRoot"));
	SetRootComponent(SceneRoot);

	Visualizer = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("SourceVisualizer"));
	Visualizer->SetupAttachment(SceneRoot);
	Visualizer->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	Visualizer->SetRelativeScale3D(FVector(0.35f));

	static ConstructorHelpers::FObjectFinder<UStaticMesh> SphereMesh(
		TEXT("/Engine/BasicShapes/Sphere.Sphere"));
	if (SphereMesh.Succeeded())
	{
		Visualizer->SetStaticMesh(SphereMesh.Object);
	}
	static ConstructorHelpers::FObjectFinder<UMaterialInterface> BasicShapeMaterial(
		TEXT("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
	if (BasicShapeMaterial.Succeeded())
	{
		Visualizer->SetMaterial(0, BasicShapeMaterial.Object);
	}

	AudioComponent = CreateDefaultSubobject<UAudioComponent>(TEXT("PulseAudio"));
	AudioComponent->SetupAttachment(SceneRoot);
	AudioComponent->bAutoActivate = false;
	AudioComponent->bAllowSpatialization = true;
	AudioComponent->SetOverrideAttenuation(true);
	FSoundAttenuationSettings SpatializedOutput;
	SpatializedOutput.bAttenuate = false;
	SpatializedOutput.bSpatialize = true;
	SpatializedOutput.SpatializationAlgorithm =
		ESoundSpatializationAlgorithm::SPATIALIZATION_HRTF;
	SpatializedOutput.NonSpatializedRadiusStart = 0.0f;
	SpatializedOutput.NonSpatializedRadiusEnd = 0.0f;
	AudioComponent->SetAttenuationOverrides(SpatializedOutput);
	AudioComponent->SetVolumeMultiplier(0.2f);

	ActivationTrigger = CreateDefaultSubobject<UCapsuleComponent>(TEXT("ActivationTrigger"));
	ActivationTrigger->SetupAttachment(SceneRoot);
	ActivationTrigger->SetRelativeLocation(FVector(0.0f, 0.0f, -200.0f));
	ActivationTrigger->SetCapsuleRadius(100.0f);
	ActivationTrigger->SetCapsuleHalfHeight(300.0f);
	ActivationTrigger->SetCollisionEnabled(ECollisionEnabled::QueryOnly);
	ActivationTrigger->SetCollisionObjectType(ECC_WorldDynamic);
	ActivationTrigger->SetCollisionResponseToAllChannels(ECR_Ignore);
	ActivationTrigger->SetCollisionResponseToChannel(ECC_Pawn, ECR_Overlap);
	ActivationTrigger->SetGenerateOverlapEvents(true);
	ActivationTrigger->OnComponentBeginOverlap.AddDynamic(
		this, &AAudioLocalizationPulseSource::OnActivationTriggerBeginOverlap);
}

void AAudioLocalizationPulseSource::EmitPulse(const TArray<float>& Waveform, int32 SampleRate)
{
	USoundWaveProcedural* ProceduralWave = NewObject<USoundWaveProcedural>(this);
	ProceduralWave->SetSampleRate(SampleRate);
	ProceduralWave->NumChannels = 1;
	ProceduralWave->Duration = static_cast<float>(Waveform.Num()) / SampleRate;
	ProceduralWave->SoundGroup = SOUNDGROUP_Default;

	TArray<uint8> PcmBytes;
	PcmBytes.SetNumUninitialized(Waveform.Num() * sizeof(int16));
	int16* Pcm = reinterpret_cast<int16*>(PcmBytes.GetData());
	for (int32 Index = 0; Index < Waveform.Num(); ++Index)
	{
		Pcm[Index] = static_cast<int16>(FMath::Clamp(Waveform[Index], -1.0f, 1.0f) * 32767.0f);
	}
	ProceduralWave->QueueAudio(PcmBytes.GetData(), PcmBytes.Num());

	AudioComponent->Stop();
	AudioComponent->SetSound(ProceduralWave);
	AudioComponent->Play();
}

void AAudioLocalizationPulseSource::InitializeInteractive(
	const TArray<float>& Waveform,
	int32 SampleRate)
{
	InteractiveWaveform = Waveform;
	InteractiveSampleRate = SampleRate;
	SetInteractiveEnabled(true);
}

void AAudioLocalizationPulseSource::BeginPlay()
{
	Super::BeginPlay();

	if (UMaterialInterface* BaseMaterial = Visualizer->GetMaterial(0))
	{
		VisualizerMaterial = UMaterialInstanceDynamic::Create(BaseMaterial, this);
		Visualizer->SetMaterial(0, VisualizerMaterial);
	}
	UpdateVisualizerState();
}

void AAudioLocalizationPulseSource::SetInteractiveEnabled(bool bEnabled)
{
	bInteractiveEnabled = bEnabled;
	ActivationTrigger->SetGenerateOverlapEvents(bEnabled);
	if (!bEnabled)
	{
		SetRepeating(false);
	}
	UpdateVisualizerState();
}

void AAudioLocalizationPulseSource::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	GetWorldTimerManager().ClearTimer(RepeatTimer);
	Super::EndPlay(EndPlayReason);
}

void AAudioLocalizationPulseSource::OnActivationTriggerBeginOverlap(
	UPrimitiveComponent* OverlappedComponent,
	AActor* OtherActor,
	UPrimitiveComponent* OtherComponent,
	int32 OtherBodyIndex,
	bool bFromSweep,
	const FHitResult& SweepResult)
{
	if (!bInteractiveEnabled || !Cast<APawn>(OtherActor))
	{
		return;
	}

	const double Now = FPlatformTime::Seconds();
	if (Now - LastToggleSeconds < ToggleCooldownSeconds)
	{
		return;
	}
	LastToggleSeconds = Now;
	SetRepeating(!bRepeating);
}

void AAudioLocalizationPulseSource::SetRepeating(bool bEnabled)
{
	if (bRepeating == bEnabled)
	{
		return;
	}
	bRepeating = bEnabled;
	GetWorldTimerManager().ClearTimer(RepeatTimer);
	if (bRepeating)
	{
		EmitInteractivePulse();
		GetWorldTimerManager().SetTimer(
			RepeatTimer,
			this,
			&AAudioLocalizationPulseSource::EmitInteractivePulse,
			FMath::Max(0.10f, RepeatIntervalSeconds),
			true);
	}
	else
	{
		AudioComponent->Stop();
	}
	UpdateVisualizerState();
	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_SOURCE_TOGGLE source=%s repeating=%s interval=%.3f"),
		*GetName(), bRepeating ? TEXT("true") : TEXT("false"),
		static_cast<double>(RepeatIntervalSeconds));
}

void AAudioLocalizationPulseSource::EmitInteractivePulse()
{
	if (bInteractiveEnabled && bRepeating && !InteractiveWaveform.IsEmpty() &&
		InteractiveSampleRate > 0)
	{
		EmitPulse(InteractiveWaveform, InteractiveSampleRate);
	}
}

void AAudioLocalizationPulseSource::UpdateVisualizerState()
{
	const FLinearColor Color = bRepeating
		? FLinearColor(1.0f, 0.02f, 0.12f, 1.0f)
		: bInteractiveEnabled
			? FLinearColor(0.02f, 0.18f, 1.0f, 1.0f)
			: FLinearColor(0.25f, 0.25f, 0.25f, 1.0f);
	if (VisualizerMaterial)
	{
		VisualizerMaterial->SetVectorParameterValue(TEXT("Color"), Color);
	}
	Visualizer->SetRelativeScale3D(bRepeating ? FVector(0.45f) : FVector(0.35f));
	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_SOURCE_VISUAL source=%s state=%s color=(%.2f,%.2f,%.2f) material=%s"),
		*GetName(), bRepeating ? TEXT("on") : TEXT("off"),
		static_cast<double>(Color.R), static_cast<double>(Color.G),
		static_cast<double>(Color.B), *GetNameSafe(VisualizerMaterial));
}

AAudioLocalizationExperiment::AAudioLocalizationExperiment()
{
	PrimaryActorTick.bCanEverTick = true;
	PrimaryActorTick.bStartWithTickEnabled = true;
	PrimaryActorTick.bTickEvenWhenPaused = true;

	SceneRoot = CreateDefaultSubobject<USceneComponent>(TEXT("SceneRoot"));
	SetRootComponent(SceneRoot);

	static ConstructorHelpers::FObjectFinder<UStaticMesh> SphereMesh(
		TEXT("/Engine/BasicShapes/Sphere.Sphere"));

	LeftMicrophone = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("LeftEarMicrophone"));
	LeftMicrophone->SetupAttachment(SceneRoot);
	LeftMicrophone->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	LeftMicrophone->SetRelativeScale3D(FVector(0.04f));
	if (SphereMesh.Succeeded())
	{
		LeftMicrophone->SetStaticMesh(SphereMesh.Object);
	}

	RightMicrophone = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("RightEarMicrophone"));
	RightMicrophone->SetupAttachment(SceneRoot);
	RightMicrophone->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	RightMicrophone->SetRelativeScale3D(FVector(0.04f));
	if (SphereMesh.Succeeded())
	{
		RightMicrophone->SetStaticMesh(SphereMesh.Object);
	}
}

void AAudioLocalizationExperiment::BeginPlay()
{
	Super::BeginPlay();
	if (GEngine)
	{
		bPreviousPauseOnLossOfFocus = GEngine->bPauseOnLossOfFocus;
		GEngine->bPauseOnLossOfFocus = false;
	}
	UGameplayStatics::SetGamePaused(this, false);
	SetActorTickEnabled(true);
	bAppHadFocusAtBegin = FApp::HasFocus();
	PreviousAppVolumeMultiplier = FApp::GetVolumeMultiplier();
	bPreviousUseVrFocus = FApp::UseVRFocus();
	bPreviousHasVrFocus = FApp::HasVRFocus();
	if (bForceAudioWhenUnfocused)
	{
		FApp::SetUseVRFocus(true);
		FApp::SetHasVRFocus(true);
		FApp::SetVolumeMultiplier(1.0f);
	}
	bAppHasFocusAfterOverride = FApp::HasFocus();
	if (!RegisterSubmixListener())
	{
		UE_LOG(LogAudioLocalization, Error,
			TEXT("AUDIO_LOCALIZATION_RENDERED: failed to register submix listener"));
		return;
	}

	SourceWaveform = AudioLocalizationSignal::GenerateChirp(
		SampleRate,
		ChirpDurationSeconds,
		StartFrequencyHz,
		EndFrequencyHz);

	TArray<AActor*> FoundActors;
	UGameplayStatics::GetAllActorsOfClass(this, AAudioLocalizationPulseSource::StaticClass(), FoundActors);
	FoundActors.Sort([](const AActor& Left, const AActor& Right)
	{
		return Left.GetName() < Right.GetName();
	});
	for (AActor* Actor : FoundActors)
	{
		Sources.Add(CastChecked<AAudioLocalizationPulseSource>(Actor));
	}

	if (Sources.IsEmpty())
	{
		UE_LOG(LogAudioLocalization, Error, TEXT("AUDIO_LOCALIZATION: no pulse source actors found"));
		return;
	}

	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_RENDERED_START sources=%d trials_per_source=%d source_sample_rate=%d capture_seconds=%.3f app_focus=%s app_volume_before=%.3f force_audio_when_unfocused=%s"),
		Sources.Num(), TrialsPerSource, SampleRate, static_cast<double>(CaptureDurationSeconds),
		bAppHadFocusAtBegin ? TEXT("true") : TEXT("false"),
		static_cast<double>(PreviousAppVolumeMultiplier),
		bForceAudioWhenUnfocused ? TEXT("true") : TEXT("false"));

	if (bContinuousStreaming)
	{
		UE_LOG(LogAudioLocalization, Display,
			TEXT("AUDIO_LOCALIZATION_STREAM_CONFIG buffer_seconds=%.3f window_ms=%.3f hop_ms=%.3f event_interval=%.3f minimum_rms=%.6f rise_ratio=%.3f"),
			static_cast<double>(StreamBufferSeconds),
			static_cast<double>(AnalysisWindowMilliseconds),
			static_cast<double>(AnalysisHopMilliseconds),
			static_cast<double>(ContinuousEventIntervalSeconds),
			static_cast<double>(OnsetMinimumRms),
			static_cast<double>(OnsetRiseRatio));
		SubmixListener->StartStreaming(StreamBufferSeconds);
		bContinuousActive = true;
		if (bInteractiveMode)
		{
			InteractiveStartSeconds = FPlatformTime::Seconds();
			for (AAudioLocalizationPulseSource* Source : Sources)
			{
				Source->InitializeInteractive(SourceWaveform, SampleRate);
			}
			UE_LOG(LogAudioLocalization, Display,
				TEXT("AUDIO_LOCALIZATION_INTERACTIVE_START sources=%d listener=avatar_pawn_view_location validate_contact=%s"),
				Sources.Num(), bApplyValidationInteractiveContact ? TEXT("true") : TEXT("false"));
			return;
		}
		// The submix callback begins only after audio is rendered. Emit the first
		// event immediately so startup never depends on an already-running callback.
		EmitNextContinuousEvent();
		return;
	}

	GetWorldTimerManager().SetTimer(
		TrialTimer,
		this,
		&AAudioLocalizationExperiment::RunNextTrial,
		InitialDelaySeconds,
		false,
		InitialDelaySeconds);
}

void AAudioLocalizationExperiment::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	FVector ListenerCenter;
	FVector ListenerForward;
	FVector ListenerRight;
	GetEarRig(ListenerCenter, ListenerForward, ListenerRight);
	VisualizationSnapshot.ListenerLocation = ListenerCenter;
	const double Now = FPlatformTime::Seconds();
	if (bInteractiveMode && bApplyValidationInteractiveContact && !Sources.IsEmpty())
	{
		if (APlayerController* PlayerController = UGameplayStatics::GetPlayerController(this, 0))
		{
			if (APawn* Pawn = PlayerController->GetPawn())
			{
				if (ValidationInteractiveContactPhase == 0 &&
					Now - InteractiveStartSeconds >= ValidationInteractiveContactDelaySeconds)
				{
					ValidationInteractiveOriginalPawnLocation = Pawn->GetActorLocation();
					FVector ContactLocation = Sources[0]->GetActorLocation();
					ContactLocation.Z = ValidationInteractiveOriginalPawnLocation.Z;
					Pawn->SetActorLocation(ContactLocation, false);
					bValidationInteractiveContactApplied = true;
					ValidationInteractiveContactPhase = 1;
					ValidationInteractiveContactPhaseSeconds = Now;
					UE_LOG(LogAudioLocalization, Display,
						TEXT("AUDIO_LOCALIZATION_INTERACTIVE_CONTACT_VALIDATION phase=contact_on source=%s"),
						*Sources[0]->GetName());
				}
				else if (ValidationInteractiveContactPhase == 1 &&
					Now - ValidationInteractiveContactPhaseSeconds >= 1.0)
				{
					Pawn->SetActorLocation(ValidationInteractiveOriginalPawnLocation, false);
					ValidationInteractiveContactPhase = 2;
					ValidationInteractiveContactPhaseSeconds = Now;
					UE_LOG(LogAudioLocalization, Display,
						TEXT("AUDIO_LOCALIZATION_INTERACTIVE_CONTACT_VALIDATION phase=leave"));
				}
				else if (ValidationInteractiveContactPhase == 2 &&
					Now - ValidationInteractiveContactPhaseSeconds >= 1.0)
				{
					FVector ContactLocation = Sources[0]->GetActorLocation();
					ContactLocation.Z = ValidationInteractiveOriginalPawnLocation.Z;
					Pawn->SetActorLocation(ContactLocation, false);
					ValidationInteractiveContactPhase = 3;
					UE_LOG(LogAudioLocalization, Display,
						TEXT("AUDIO_LOCALIZATION_INTERACTIVE_CONTACT_VALIDATION phase=contact_off source=%s"),
						*Sources[0]->GetName());
				}
			}
		}
	}
	if (!bContinuousActive)
	{
		return;
	}

	AnalyzeContinuousStream();
	UpdateVisualizationSnapshot();
	if (bInteractiveMode)
	{
		return;
	}
	if (FPlatformTime::Seconds() < NextContinuousActionSeconds)
	{
		return;
	}

	if (Sources.IsValidIndex(ContinuousSourceIndex))
	{
		EmitNextContinuousEvent();
	}
	else if (bContinuousFinishing)
	{
		FinishContinuousExperiment();
	}
}

void AAudioLocalizationExperiment::GetVisualizationSnapshot(
	FAudioLocalizationVisualizationSnapshot& OutSnapshot) const
{
	OutSnapshot = VisualizationSnapshot;
}

void AAudioLocalizationExperiment::UpdateVisualizationSnapshot()
{
	const double Now = FPlatformTime::Seconds();
	if (Now < NextVisualizationUpdateSeconds || !SubmixListener.IsValid())
	{
		return;
	}
	NextVisualizationUpdateSeconds = Now + FMath::Max(0.01f, VisualizationRefreshSeconds);

	VisualizationSnapshot.ActiveSourceCount = 0;
	for (const AAudioLocalizationPulseSource* Source : Sources)
	{
		VisualizationSnapshot.ActiveSourceCount += Source && Source->IsRepeating() ? 1 : 0;
	}

	int32 RenderedChannels = 0;
	int32 RenderedSampleRate = 0;
	int64 TotalFrames = 0;
	if (!SubmixListener->GetStreamState(RenderedChannels, RenderedSampleRate, TotalFrames))
	{
		VisualizationSnapshot.bStreamReady = false;
		return;
	}

	const int32 RequestedFrames = FMath::Max(2, FMath::RoundToInt(
		VisualizationHistorySeconds * RenderedSampleRate));
	const int32 AvailableFrames = static_cast<int32>(FMath::Min<int64>(TotalFrames, RequestedFrames));
	if (AvailableFrames < 2)
	{
		return;
	}

	TArray<float> Left;
	TArray<float> Right;
	if (!SubmixListener->ReadStereoFrames(
		TotalFrames - AvailableFrames, AvailableFrames, Left, Right))
	{
		return;
	}

	VisualizationSnapshot.LeftWaveform = MoveTemp(Left);
	VisualizationSnapshot.RightWaveform = MoveTemp(Right);
	VisualizationSnapshot.LeftRms = RootMeanSquare(VisualizationSnapshot.LeftWaveform);
	VisualizationSnapshot.RightRms = RootMeanSquare(VisualizationSnapshot.RightWaveform);
	VisualizationSnapshot.bStreamReady = true;
}

void AAudioLocalizationExperiment::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	bContinuousActive = false;
	if (APlayerController* PlayerController = UGameplayStatics::GetPlayerController(this, 0))
	{
		PlayerController->ClearAudioListenerOverride();
	}
	for (AAudioLocalizationPulseSource* Source : Sources)
	{
		if (Source)
		{
			Source->SetInteractiveEnabled(false);
		}
	}
	if (GEngine)
	{
		GEngine->bPauseOnLossOfFocus = bPreviousPauseOnLossOfFocus;
	}
	GetWorldTimerManager().ClearTimer(TrialTimer);
	GetWorldTimerManager().ClearTimer(AnalysisTimer);
	if (SubmixListener.IsValid())
	{
		SubmixListener->StopStreaming();
	}
	UnregisterSubmixListener();
	if (bForceAudioWhenUnfocused)
	{
		FApp::SetVolumeMultiplier(PreviousAppVolumeMultiplier);
		FApp::SetHasVRFocus(bPreviousHasVrFocus);
		FApp::SetUseVRFocus(bPreviousUseVrFocus);
	}
	Super::EndPlay(EndPlayReason);
}

bool AAudioLocalizationExperiment::RegisterSubmixListener()
{
	if (!GetWorld())
	{
		return false;
	}
	FAudioDeviceHandle AudioDevice = GetWorld()->GetAudioDevice();
	if (!AudioDevice)
	{
		return false;
	}
	const FAudioDevice::FAudioSpatializationInterfaceInfo SpatializationInfo =
		AudioDevice->GetCurrentSpatializationPluginInterfaceInfo();
	ActiveSpatializationPlugin = SpatializationInfo.PluginName.ToString();
	if (!SpatializationInfo.IsValid() || ActiveSpatializationPlugin != TEXT("Resonance Audio"))
	{
		UE_LOG(LogAudioLocalization, Error,
			TEXT("AUDIO_LOCALIZATION_HRTF: expected Resonance Audio spatializer, active=%s"),
			*ActiveSpatializationPlugin);
		return false;
	}
	SubmixListener = MakeShared<FAudioLocalizationSubmixListener, ESPMode::ThreadSafe>();
	AudioDevice->RegisterSubmixBufferListener(
		SubmixListener.ToSharedRef(),
		AudioDevice->GetMainSubmixObject());
	return true;
}

void AAudioLocalizationExperiment::UnregisterSubmixListener()
{
	if (!SubmixListener.IsValid() || !GetWorld())
	{
		return;
	}
	if (FAudioDeviceHandle AudioDevice = GetWorld()->GetAudioDevice())
	{
		AudioDevice->UnregisterSubmixBufferListener(
			SubmixListener.ToSharedRef(),
			AudioDevice->GetMainSubmixObject());
	}
	SubmixListener.Reset();
}

bool AAudioLocalizationExperiment::GetEarRig(
	FVector& OutCenter,
	FVector& OutForward,
	FVector& OutRight)
{
	APlayerController* PlayerController = UGameplayStatics::GetPlayerController(this, 0);
	APawn* Pawn = PlayerController ? PlayerController->GetPawn() : nullptr;
	if (!PlayerController || !Pawn)
	{
		return false;
	}

	FVector CameraLocation;
	FRotator CameraRotation;
	PlayerController->GetPlayerViewPoint(CameraLocation, CameraRotation);
	const FRotator YawRotation(0.0f, CameraRotation.Yaw, 0.0f);
	OutCenter = Pawn->GetPawnViewLocation();
	OutForward = YawRotation.Vector();
	OutRight = FRotationMatrix(YawRotation).GetUnitAxis(EAxis::Y);

	// Attach Unreal's actual HRTF listener to the avatar head while retaining
	// camera-relative yaw. The location/rotation arguments are relative when an
	// attachment component is supplied.
	USceneComponent* PawnRoot = Pawn->GetRootComponent();
	if (PawnRoot)
	{
		const FRotator RelativeRotation = (YawRotation - PawnRoot->GetComponentRotation()).GetNormalized();
		const FVector RelativeLocation = YawRotation.UnrotateVector(
			OutCenter - PawnRoot->GetComponentLocation());
		PlayerController->SetAudioListenerOverride(
			PawnRoot, RelativeLocation, RelativeRotation);
	}
	else
	{
		PlayerController->SetAudioListenerOverride(nullptr, OutCenter, YawRotation);
	}
	PlayerController->GetAudioListenerPosition(OutCenter, OutForward, OutRight);

	SetActorLocationAndRotation(OutCenter, YawRotation);
	LeftMicrophone->SetRelativeLocation(FVector(0.0f, -EarSpacingCentimeters * 0.5f, 0.0f));
	RightMicrophone->SetRelativeLocation(FVector(0.0f, EarSpacingCentimeters * 0.5f, 0.0f));
	return true;
}

void AAudioLocalizationExperiment::EmitNextContinuousEvent()
{
	if (!Sources.IsValidIndex(ContinuousSourceIndex) || !SubmixListener.IsValid())
	{
		FinishContinuousExperiment();
		return;
	}

	int32 RenderedChannels = 0;
	int32 RenderedSampleRate = 0;
	int64 TotalFrames = 0;
	const bool bStreamReady = SubmixListener->GetStreamState(
		RenderedChannels, RenderedSampleRate, TotalFrames);
	if (bApplyValidationAvatarMotion && !bValidationAvatarMotionApplied &&
		ContinuousSourceIndex == Sources.Num() / 2)
	{
		if (APlayerController* PlayerController = UGameplayStatics::GetPlayerController(this, 0))
		{
			if (APawn* Pawn = PlayerController->GetPawn())
			{
				const FRotator YawRotation(0.0f, PlayerController->GetControlRotation().Yaw, 0.0f);
				const FVector Offset = YawRotation.Vector() * ValidationAvatarForwardOffsetCentimeters;
				Pawn->AddActorWorldOffset(Offset, false);
				bValidationAvatarMotionApplied = true;
				UE_LOG(LogAudioLocalization, Display,
					TEXT("AUDIO_LOCALIZATION_AVATAR_MOVED offset=(%.2f,%.2f,%.2f)"),
					static_cast<double>(Offset.X), static_cast<double>(Offset.Y),
					static_cast<double>(Offset.Z));
			}
		}
	}

	FVector EarCenter;
	FVector CameraForward;
	FVector CameraRight;
	if (!GetEarRig(EarCenter, CameraForward, CameraRight))
	{
		FinishContinuousExperiment();
		return;
	}

	AAudioLocalizationPulseSource* Source = Sources[ContinuousSourceIndex];
	const FVector Direction = (Source->GetActorLocation() - EarCenter).GetSafeNormal();
	const float AzimuthDegrees = FMath::RadiansToDegrees(FMath::Atan2(
		FVector::DotProduct(Direction, CameraRight),
		FVector::DotProduct(Direction, CameraForward)));
	const float AbsoluteAzimuth = FMath::Abs(AzimuthDegrees);
	const bool bAmbiguous = AbsoluteAzimuth < AmbiguousAngleDegrees ||
		FMath::Abs(180.0f - AbsoluteAzimuth) < AmbiguousAngleDegrees;

	FAudioLocalizationExpectedEvent& Event = ExpectedContinuousEvents.AddDefaulted_GetRef();
	Event.SourceIndex = ContinuousSourceIndex;
	Event.EmittedAfterFrame = TotalFrames;
	Event.AzimuthDegrees = AzimuthDegrees;
	Event.ListenerLocation = EarCenter;
	Event.GroundTruth = bAmbiguous ? TEXT("Unknown") : SideFromAzimuth(AzimuthDegrees);

	Source->EmitPulse(SourceWaveform, SampleRate);
	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_STREAM_EMIT source=%s index=%d after_frame=%lld azimuth=%.2f truth=%s listener=(%.2f,%.2f,%.2f) stream_ready=%s"),
		*Source->GetName(), ContinuousSourceIndex, TotalFrames,
		static_cast<double>(AzimuthDegrees), *Event.GroundTruth,
		static_cast<double>(EarCenter.X), static_cast<double>(EarCenter.Y),
		static_cast<double>(EarCenter.Z),
		bStreamReady ? TEXT("true") : TEXT("false"));

	++ContinuousSourceIndex;
	if (Sources.IsValidIndex(ContinuousSourceIndex))
	{
		NextContinuousActionSeconds = FPlatformTime::Seconds() + ContinuousEventIntervalSeconds;
	}
	else
	{
		bContinuousFinishing = true;
		NextContinuousActionSeconds = FPlatformTime::Seconds() +
			FMath::Max(0.50f, ContinuousEventIntervalSeconds);
	}
}

void AAudioLocalizationExperiment::AnalyzeContinuousStream()
{
	if (!SubmixListener.IsValid())
	{
		return;
	}

	int32 RenderedChannels = 0;
	int32 RenderedSampleRate = 0;
	int64 TotalFrames = 0;
	if (!SubmixListener->GetStreamState(RenderedChannels, RenderedSampleRate, TotalFrames))
	{
		return;
	}

	const int32 WindowFrames = FMath::Max(2, FMath::RoundToInt(
		AnalysisWindowMilliseconds * 0.001f * RenderedSampleRate));
	const int32 HopFrames = FMath::Max(1, FMath::RoundToInt(
		AnalysisHopMilliseconds * 0.001f * RenderedSampleRate));
	const int64 RefractoryFrames = FMath::RoundToInt64(0.15 * RenderedSampleRate);
	const int64 MaximumMatchDelayFrames = FMath::RoundToInt64(0.50 * RenderedSampleRate);

	// Bound each game-thread pass so a delayed callback catches up over several
	// ticks instead of monopolizing PIE startup.
	constexpr int32 MaximumWindowsPerPass = 512;
	int32 WindowsProcessed = 0;
	while (NextAnalysisFrame + WindowFrames <= TotalFrames &&
		WindowsProcessed++ < MaximumWindowsPerPass)
	{
		TArray<float> Left;
		TArray<float> Right;
		if (!SubmixListener->ReadStereoFrames(NextAnalysisFrame, WindowFrames, Left, Right))
		{
			const int64 EarliestRetainedFrame = FMath::Max<int64>(
				0, TotalFrames - FMath::RoundToInt64(StreamBufferSeconds * RenderedSampleRate));
			const int64 FirstReadableHop = FMath::DivideAndRoundUp(
				EarliestRetainedFrame, static_cast<int64>(HopFrames)) * HopFrames;
			NextAnalysisFrame = FMath::Max(NextAnalysisFrame + HopFrames, FirstReadableHop);
			continue;
		}

		const float LeftRms = RootMeanSquare(Left);
		const float RightRms = RootMeanSquare(Right);
		const float CombinedRms = FMath::Sqrt(0.5f *
			(LeftRms * LeftRms + RightRms * RightRms));
		MaximumObservedWindowRms = FMath::Max(MaximumObservedWindowRms, CombinedRms);
		const int64 DetectionFrame = NextAnalysisFrame + WindowFrames;
		const bool bAboveFloor = CombinedRms >= OnsetMinimumRms;
		const bool bRising = CombinedRms >= FMath::Max(
			OnsetMinimumRms, NoiseFloorRms * OnsetRiseRatio);
		const bool bOutsideRefractory = LastDetectionFrame == MIN_int64 ||
			DetectionFrame - LastDetectionFrame >= RefractoryFrames;

		if (bAboveFloor && bRising && bOutsideRefractory)
		{
			const int32 MaximumLagSamples = FMath::CeilToInt(
				(EarSpacingCentimeters / 100.0f) /
				SpeedOfSoundMetersPerSecond * RenderedSampleRate) + 2;
			const AudioLocalizationSignal::FEstimate Estimate =
				AudioLocalizationSignal::EstimateSide(
					Left, Right, RenderedSampleRate, MaximumLagSamples, 0.80f);
			VisualizationSnapshot.Prediction = Estimate.Prediction;
			VisualizationSnapshot.LagSamples = Estimate.LagSamples;
			VisualizationSnapshot.IldDb = Estimate.InterauralLevelDifferenceDb;
			VisualizationSnapshot.Correlation = Estimate.Correlation;

			int32 MatchedEventIndex = INDEX_NONE;
			int64 BestDelayFrames = MAX_int64;
			for (int32 EventIndex = 0; EventIndex < ExpectedContinuousEvents.Num(); ++EventIndex)
			{
				const FAudioLocalizationExpectedEvent& Event = ExpectedContinuousEvents[EventIndex];
				const int64 DelayFrames = DetectionFrame - Event.EmittedAfterFrame;
				if (!Event.bMatched && DelayFrames >= 0 &&
					DelayFrames <= MaximumMatchDelayFrames && DelayFrames < BestDelayFrames)
				{
					MatchedEventIndex = EventIndex;
					BestDelayFrames = DelayFrames;
				}
			}

			FString GroundTruth = TEXT("Unmatched");
			bool bCorrect = false;
			if (ExpectedContinuousEvents.IsValidIndex(MatchedEventIndex))
			{
				FAudioLocalizationExpectedEvent& Event = ExpectedContinuousEvents[MatchedEventIndex];
				Event.bMatched = true;
				GroundTruth = Event.GroundTruth;
				bCorrect = Estimate.Prediction == GroundTruth;
				ContinuousCorrectDetections += bCorrect ? 1 : 0;
			}
			else if (!bInteractiveMode)
			{
				++ContinuousFalsePositives;
			}
			else
			{
				GroundTruth = TEXT("Interactive");
			}
			if (!bInteractiveMode)
			{
				ContinuousUnknownDetections += Estimate.Prediction == TEXT("Unknown") ? 1 : 0;
			}

			TSharedPtr<FJsonObject> Detection = MakeShared<FJsonObject>();
			Detection->SetNumberField(TEXT("window_start_frame"), NextAnalysisFrame);
			Detection->SetNumberField(TEXT("detection_frame"), DetectionFrame);
			Detection->SetNumberField(TEXT("detection_seconds"),
				static_cast<double>(DetectionFrame) / RenderedSampleRate);
			Detection->SetNumberField(TEXT("matched_event_index"), MatchedEventIndex);
			Detection->SetNumberField(TEXT("latency_milliseconds"),
				MatchedEventIndex != INDEX_NONE
					? 1000.0 * static_cast<double>(BestDelayFrames) / RenderedSampleRate
					: -1.0);
			Detection->SetStringField(TEXT("ground_truth"), GroundTruth);
			Detection->SetStringField(TEXT("prediction"), Estimate.Prediction);
			Detection->SetBoolField(TEXT("correct"), bCorrect);
			Detection->SetNumberField(TEXT("combined_rms"), CombinedRms);
			Detection->SetNumberField(TEXT("left_rms"), LeftRms);
			Detection->SetNumberField(TEXT("right_rms"), RightRms);
			Detection->SetNumberField(TEXT("lag_samples"), Estimate.LagSamples);
			Detection->SetNumberField(TEXT("ild_db"), Estimate.InterauralLevelDifferenceDb);
			Detection->SetNumberField(TEXT("correlation"), Estimate.Correlation);
			if (!bInteractiveMode)
			{
				ContinuousDetectionJson.Add(MakeShared<FJsonValueObject>(Detection));
			}

			LastDetectionFrame = DetectionFrame;
			UE_LOG(LogAudioLocalization, Display,
				TEXT("AUDIO_LOCALIZATION_STREAM_DETECT frame=%lld rms=%.6f truth=%s prediction=%s lag=%d ild=%.3f matched=%d correct=%s"),
				DetectionFrame, static_cast<double>(CombinedRms), *GroundTruth,
				*Estimate.Prediction, Estimate.LagSamples,
				static_cast<double>(Estimate.InterauralLevelDifferenceDb), MatchedEventIndex,
				bCorrect ? TEXT("true") : TEXT("false"));
		}

		if (CombinedRms < OnsetMinimumRms)
		{
			NoiseFloorRms = FMath::Lerp(NoiseFloorRms, CombinedRms, 0.02f);
		}
		NextAnalysisFrame += HopFrames;
	}
}

void AAudioLocalizationExperiment::FinishContinuousExperiment()
{
	if (!bContinuousFinishing && ExpectedContinuousEvents.IsEmpty())
	{
		return;
	}
	bContinuousFinishing = false;
	bContinuousActive = false;
	AnalyzeContinuousStream();
	GetWorldTimerManager().ClearTimer(TrialTimer);
	GetWorldTimerManager().ClearTimer(AnalysisTimer);
	if (SubmixListener.IsValid())
	{
		SubmixListener->StopStreaming();
	}

	int32 MatchedEvents = 0;
	TArray<TSharedPtr<FJsonValue>> EventJson;
	for (const FAudioLocalizationExpectedEvent& Event : ExpectedContinuousEvents)
	{
		MatchedEvents += Event.bMatched ? 1 : 0;
		TSharedPtr<FJsonObject> EventObject = MakeShared<FJsonObject>();
		EventObject->SetNumberField(TEXT("source_index"), Event.SourceIndex);
		EventObject->SetNumberField(TEXT("emitted_after_frame"), Event.EmittedAfterFrame);
		EventObject->SetNumberField(TEXT("azimuth_degrees"), Event.AzimuthDegrees);
		EventObject->SetNumberField(TEXT("listener_x_cm"), Event.ListenerLocation.X);
		EventObject->SetNumberField(TEXT("listener_y_cm"), Event.ListenerLocation.Y);
		EventObject->SetNumberField(TEXT("listener_z_cm"), Event.ListenerLocation.Z);
		EventObject->SetStringField(TEXT("ground_truth"), Event.GroundTruth);
		EventObject->SetBoolField(TEXT("matched"), Event.bMatched);
		EventJson.Add(MakeShared<FJsonValueObject>(EventObject));
	}

	const int32 ExpectedCount = ExpectedContinuousEvents.Num();
	const int32 DetectionCount = ContinuousDetectionJson.Num();
	const float Recall = ExpectedCount > 0
		? static_cast<float>(MatchedEvents) / ExpectedCount : 0.0f;
	const float Precision = DetectionCount > 0
		? static_cast<float>(MatchedEvents) / DetectionCount : 0.0f;
	const float SideAccuracy = MatchedEvents > 0
		? static_cast<float>(ContinuousCorrectDetections) / MatchedEvents : 0.0f;

	TSharedPtr<FJsonObject> Report = MakeShared<FJsonObject>();
	Report->SetStringField(TEXT("engine"), FEngineVersion::Current().ToString());
	Report->SetStringField(TEXT("experiment_mode"), TEXT("continuous_hrtf_stream"));
	Report->SetStringField(TEXT("spatialization"), TEXT("resonance_audio_hrtf"));
	Report->SetStringField(TEXT("active_spatialization_plugin"), ActiveSpatializationPlugin);
	Report->SetStringField(TEXT("listener_placement"), TEXT("avatar_pawn_view_location"));
	Report->SetNumberField(TEXT("virtual_ear_spacing_cm"), EarSpacingCentimeters);
	Report->SetBoolField(TEXT("validation_avatar_motion_enabled"), bApplyValidationAvatarMotion);
	Report->SetBoolField(TEXT("validation_avatar_motion_applied"), bValidationAvatarMotionApplied);
	Report->SetNumberField(TEXT("analysis_window_ms"), AnalysisWindowMilliseconds);
	Report->SetNumberField(TEXT("analysis_hop_ms"), AnalysisHopMilliseconds);
	Report->SetNumberField(TEXT("onset_minimum_rms"), OnsetMinimumRms);
	Report->SetNumberField(TEXT("onset_rise_ratio"), OnsetRiseRatio);
	Report->SetNumberField(TEXT("final_noise_floor_rms"), NoiseFloorRms);
	Report->SetNumberField(TEXT("maximum_observed_window_rms"), MaximumObservedWindowRms);
	Report->SetNumberField(TEXT("expected_events"), ExpectedCount);
	Report->SetNumberField(TEXT("matched_events"), MatchedEvents);
	Report->SetNumberField(TEXT("missed_events"), ExpectedCount - MatchedEvents);
	Report->SetNumberField(TEXT("detections"), DetectionCount);
	Report->SetNumberField(TEXT("false_positives"), ContinuousFalsePositives);
	Report->SetNumberField(TEXT("unknown_detections"), ContinuousUnknownDetections);
	Report->SetNumberField(TEXT("correct_side_detections"), ContinuousCorrectDetections);
	Report->SetNumberField(TEXT("event_recall"), Recall);
	Report->SetNumberField(TEXT("event_precision"), Precision);
	Report->SetNumberField(TEXT("side_accuracy"), SideAccuracy);
	Report->SetArrayField(TEXT("events"), EventJson);
	Report->SetArrayField(TEXT("detections_detail"), ContinuousDetectionJson);

	FString Json;
	const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Json);
	FJsonSerializer::Serialize(Report.ToSharedRef(), Writer);
	const FString OutputDirectory = FPaths::ProjectSavedDir() / TEXT("AudioLocalization");
	IFileManager::Get().MakeDirectory(*OutputDirectory, true);
	const FString OutputPath = OutputDirectory / TEXT("continuous-hrtf-results.json");
	const bool bSaved = FFileHelper::SaveStringToFile(Json, *OutputPath);

	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_STREAM_COMPLETE expected=%d matched=%d detections=%d false_positive=%d recall=%.3f precision=%.3f side_accuracy=%.3f saved=%s path=%s"),
		ExpectedCount, MatchedEvents, DetectionCount, ContinuousFalsePositives,
		static_cast<double>(Recall), static_cast<double>(Precision),
		static_cast<double>(SideAccuracy), bSaved ? TEXT("true") : TEXT("false"),
		*OutputPath);
}

void AAudioLocalizationExperiment::RunNextTrial()
{
	if (!Sources.IsValidIndex(CurrentSourceIndex))
	{
		FinishExperiment();
		return;
	}

	FVector EarCenter;
	FVector CameraForward;
	FVector CameraRight;
	if (!GetEarRig(EarCenter, CameraForward, CameraRight))
	{
		UE_LOG(LogAudioLocalization, Error, TEXT("AUDIO_LOCALIZATION: player ear rig unavailable"));
		FinishExperiment();
		return;
	}

	AAudioLocalizationPulseSource* Source = Sources[CurrentSourceIndex];
	const FVector Direction = (Source->GetActorLocation() - EarCenter).GetSafeNormal();
	PendingAzimuthDegrees = FMath::RadiansToDegrees(FMath::Atan2(
		FVector::DotProduct(Direction, CameraRight),
		FVector::DotProduct(Direction, CameraForward)));
	const float AbsoluteAzimuth = FMath::Abs(PendingAzimuthDegrees);
	bPendingAmbiguous = AbsoluteAzimuth < AmbiguousAngleDegrees ||
		FMath::Abs(180.0f - AbsoluteAzimuth) < AmbiguousAngleDegrees;
	PendingGroundTruth = bPendingAmbiguous
		? TEXT("Unknown")
		: SideFromAzimuth(PendingAzimuthDegrees);

	if (!SubmixListener.IsValid())
	{
		UE_LOG(LogAudioLocalization, Error,
			TEXT("AUDIO_LOCALIZATION_RENDERED: submix listener unavailable"));
		FinishExperiment();
		return;
	}
	SubmixListener->BeginCapture();
	Source->EmitPulse(SourceWaveform, SampleRate);
	GetWorldTimerManager().SetTimer(
		TrialTimer,
		this,
		&AAudioLocalizationExperiment::CompleteRenderedTrial,
		CaptureDurationSeconds,
		false);
}

void AAudioLocalizationExperiment::CompleteRenderedTrial()
{
	if (!Sources.IsValidIndex(CurrentSourceIndex) || !SubmixListener.IsValid())
	{
		FinishExperiment();
		return;
	}

	TArray<float> Interleaved;
	int32 NumChannels = 0;
	int32 RenderedSampleRate = 0;
	bool bFormatChanged = false;
	const bool bCaptured = SubmixListener->EndCapture(
		Interleaved, NumChannels, RenderedSampleRate, bFormatChanged);
	TArray<float> LeftWaveform;
	TArray<float> RightWaveform;
	int32 RawCapturedFrames = 0;
	const bool bStereoExtracted = bCaptured && ExtractActiveStereo(
		Interleaved,
		NumChannels,
		LeftWaveform,
		RightWaveform,
		RawCapturedFrames);

	AudioLocalizationSignal::FEstimate Estimate;
	if (bStereoExtracted && !bFormatChanged)
	{
		const int32 MaximumLagSamples = FMath::CeilToInt(
			(EarSpacingCentimeters / 100.0f) /
			SpeedOfSoundMetersPerSecond * RenderedSampleRate) + 2;
		Estimate = AudioLocalizationSignal::EstimateSide(
			LeftWaveform,
			RightWaveform,
			RenderedSampleRate,
			MaximumLagSamples,
			0.80f);
	}

	const bool bCorrect = Estimate.Prediction == PendingGroundTruth;
	if (!bPendingAmbiguous)
	{
		++EvaluatedTrials;
		CorrectTrials += bCorrect ? 1 : 0;
	}
	UnknownTrials += Estimate.Prediction == TEXT("Unknown") ? 1 : 0;

	AAudioLocalizationPulseSource* Source = Sources[CurrentSourceIndex];
	TSharedPtr<FJsonObject> Trial = MakeShared<FJsonObject>();
	Trial->SetStringField(TEXT("source"), Source->GetName());
	Trial->SetNumberField(TEXT("source_index"), CurrentSourceIndex);
	Trial->SetNumberField(TEXT("repetition"), CurrentRepetition);
	Trial->SetNumberField(TEXT("azimuth_degrees"), PendingAzimuthDegrees);
	Trial->SetStringField(TEXT("ground_truth"), PendingGroundTruth);
	Trial->SetStringField(TEXT("prediction"), Estimate.Prediction);
	Trial->SetBoolField(TEXT("correct"), bCorrect);
	Trial->SetStringField(TEXT("capture_path"), TEXT("main_output_submix"));
	Trial->SetBoolField(TEXT("captured"), bCaptured);
	Trial->SetBoolField(TEXT("format_changed"), bFormatChanged);
	Trial->SetNumberField(TEXT("rendered_sample_rate"), RenderedSampleRate);
	Trial->SetNumberField(TEXT("rendered_channels"), NumChannels);
	Trial->SetNumberField(TEXT("raw_captured_frames"), RawCapturedFrames);
	Trial->SetNumberField(TEXT("active_frames"), LeftWaveform.Num());
	Trial->SetNumberField(TEXT("left_rms"), RootMeanSquare(LeftWaveform));
	Trial->SetNumberField(TEXT("right_rms"), RootMeanSquare(RightWaveform));
	Trial->SetNumberField(TEXT("lag_samples"), Estimate.LagSamples);
	Trial->SetNumberField(TEXT("lag_milliseconds"), Estimate.LagMilliseconds);
	Trial->SetNumberField(TEXT("ild_db"), Estimate.InterauralLevelDifferenceDb);
	Trial->SetNumberField(TEXT("correlation"), Estimate.Correlation);
	TrialJson.Add(MakeShared<FJsonValueObject>(Trial));

	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_RENDERED_TRIAL source=%s rep=%d azimuth=%.2f truth=%s prediction=%s channels=%d frames=%d lag=%d ild=%.4f corr=%.5f correct=%s"),
		*Source->GetName(), CurrentRepetition, static_cast<double>(PendingAzimuthDegrees),
		*PendingGroundTruth,
		*Estimate.Prediction, NumChannels, LeftWaveform.Num(), Estimate.LagSamples,
		static_cast<double>(Estimate.InterauralLevelDifferenceDb),
		static_cast<double>(Estimate.Correlation), bCorrect ? TEXT("true") : TEXT("false"));

	++CurrentRepetition;
	if (CurrentRepetition >= TrialsPerSource)
	{
		CurrentRepetition = 0;
		++CurrentSourceIndex;
	}

	if (Sources.IsValidIndex(CurrentSourceIndex))
	{
		GetWorldTimerManager().SetTimer(
			TrialTimer,
			this,
			&AAudioLocalizationExperiment::RunNextTrial,
			PulseIntervalSeconds,
			false);
	}
	else
	{
		FinishExperiment();
	}
}

void AAudioLocalizationExperiment::FinishExperiment()
{
	GetWorldTimerManager().ClearTimer(TrialTimer);
	const float Accuracy = EvaluatedTrials > 0
		? static_cast<float>(CorrectTrials) / static_cast<float>(EvaluatedTrials)
		: 0.0f;

	TSharedPtr<FJsonObject> Report = MakeShared<FJsonObject>();
	Report->SetStringField(TEXT("engine"), FEngineVersion::Current().ToString());
	Report->SetStringField(TEXT("experiment_mode"), TEXT("hrtf_main_output_submix"));
	Report->SetStringField(TEXT("spatialization"), TEXT("resonance_audio_hrtf"));
	Report->SetStringField(TEXT("active_spatialization_plugin"), ActiveSpatializationPlugin);
	Report->SetBoolField(TEXT("app_had_focus_at_begin"), bAppHadFocusAtBegin);
	Report->SetBoolField(TEXT("app_has_focus_after_override"), bAppHasFocusAfterOverride);
	Report->SetNumberField(TEXT("app_volume_multiplier_before_override"), PreviousAppVolumeMultiplier);
	Report->SetBoolField(TEXT("force_audio_when_unfocused"), bForceAudioWhenUnfocused);
	Report->SetNumberField(TEXT("source_sample_rate"), SampleRate);
	Report->SetNumberField(TEXT("capture_duration_seconds"), CaptureDurationSeconds);
	Report->SetNumberField(TEXT("ear_spacing_cm"), EarSpacingCentimeters);
	Report->SetNumberField(TEXT("speed_of_sound_m_s"), SpeedOfSoundMetersPerSecond);
	Report->SetNumberField(TEXT("source_count"), Sources.Num());
	Report->SetNumberField(TEXT("trials_per_source"), TrialsPerSource);
	Report->SetNumberField(TEXT("evaluated_trials"), EvaluatedTrials);
	Report->SetNumberField(TEXT("correct_trials"), CorrectTrials);
	Report->SetNumberField(TEXT("unknown_trials"), UnknownTrials);
	Report->SetNumberField(TEXT("accuracy"), Accuracy);
	Report->SetArrayField(TEXT("trials"), TrialJson);

	FString Json;
	const TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Json);
	FJsonSerializer::Serialize(Report.ToSharedRef(), Writer);
	const FString OutputDirectory = FPaths::ProjectSavedDir() / TEXT("AudioLocalization");
	IFileManager::Get().MakeDirectory(*OutputDirectory, true);
	const FString OutputFilename = bForceAudioWhenUnfocused
		? TEXT("hrtf-results.json")
		: TEXT("hrtf-focused-control-results.json");
	const FString OutputPath = OutputDirectory / OutputFilename;
	const bool bSaved = FFileHelper::SaveStringToFile(Json, *OutputPath);

	UE_LOG(LogAudioLocalization, Display,
		TEXT("AUDIO_LOCALIZATION_RENDERED_COMPLETE evaluated=%d correct=%d unknown=%d accuracy=%.4f saved=%s path=%s"),
		EvaluatedTrials, CorrectTrials, UnknownTrials, static_cast<double>(Accuracy),
		bSaved ? TEXT("true") : TEXT("false"), *OutputPath);
}

#if WITH_DEV_AUTOMATION_TESTS

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAudioLocalizationSignalTest,
	"AudioLocalization.Signal.VirtualMicrophoneSide",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAudioLocalizationSignalTest::RunTest(const FString& Parameters)
{
	constexpr int32 TestSampleRate = 48000;
	const TArray<float> Chirp = AudioLocalizationSignal::GenerateChirp(
		TestSampleRate, 0.020f, 500.0f, 4000.0f);
	const FVector Center = FVector::ZeroVector;
	const FVector LeftEar(0.0f, -9.0f, 0.0f);
	const FVector RightEar(0.0f, 9.0f, 0.0f);

	auto CheckSide = [this, &Chirp, &Center, &LeftEar, &RightEar, TestSampleRate](
		const FVector& Source,
		const FString& Expected)
	{
		TArray<float> Left;
		TArray<float> Right;
		float LeftDistance = 0.0f;
		float RightDistance = 0.0f;
		AudioLocalizationSignal::SynthesizeVirtualMicrophones(
			Chirp, TestSampleRate, 343.0f, Source, LeftEar, RightEar,
			Left, Right, LeftDistance, RightDistance);
		const AudioLocalizationSignal::FEstimate Estimate =
			AudioLocalizationSignal::EstimateSide(Left, Right, TestSampleRate, 28, 0.80f);
		TestEqual(FString::Printf(TEXT("%s source prediction"), *Expected), Estimate.Prediction, Expected);
		TestTrue(TEXT("Correlation is high"), Estimate.Correlation > 0.95f);
	};

	CheckSide(FVector(0.0f, -500.0f, 0.0f), TEXT("Left"));
	CheckSide(FVector(0.0f, 500.0f, 0.0f), TEXT("Right"));

	TArray<float> PannedLeft = Chirp;
	TArray<float> PannedRight = Chirp;
	for (int32 Index = 0; Index < Chirp.Num(); ++Index)
	{
		PannedLeft[Index] *= 0.2f;
		PannedRight[Index] *= 0.8f;
	}
	const AudioLocalizationSignal::FEstimate PannedEstimate =
		AudioLocalizationSignal::EstimateSide(
			PannedLeft, PannedRight, TestSampleRate, 28, 0.80f);
	TestEqual(TEXT("Rendered stereo ILD predicts right"),
		PannedEstimate.Prediction, FString(TEXT("Right")));

	PannedLeft = Chirp;
	PannedRight.Init(0.0f, Chirp.Num());
	const AudioLocalizationSignal::FEstimate HardLeftEstimate =
		AudioLocalizationSignal::EstimateSide(
			PannedLeft, PannedRight, TestSampleRate, 28, 0.80f);
	TestEqual(TEXT("One-sided rendered audio uses ILD fallback"),
		HardLeftEstimate.Prediction, FString(TEXT("Left")));
	return true;
}

#endif
