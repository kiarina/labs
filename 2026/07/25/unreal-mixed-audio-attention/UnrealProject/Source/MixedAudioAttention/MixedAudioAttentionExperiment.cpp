#include "MixedAudioAttentionExperiment.h"

#include "AudioDevice.h"
#include "AudioMixerDevice.h"
#include "Components/AudioComponent.h"
#include "Components/SphereComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Components/TextRenderComponent.h"
#include "Engine/Engine.h"
#include "Engine/StaticMesh.h"
#include "GameFramework/PlayerController.h"
#include "HAL/PlatformFileManager.h"
#include "ISubmixBufferListener.h"
#include "JsonObjectConverter.h"
#include "Kismet/GameplayStatics.h"
#include "Misc/CommandLine.h"
#include "Misc/App.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/ScopeLock.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "Sound/SoundAttenuation.h"
#include "Sound/SoundWaveProcedural.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "UObject/ConstructorHelpers.h"

DEFINE_LOG_CATEGORY_STATIC(LogMixedAudioAttention, Log, All);

namespace
{
	TArray<uint8> ToPcm16(const TArray<float>& Samples)
	{
		TArray<uint8> Bytes; Bytes.SetNumUninitialized(Samples.Num() * 2); int16* Pcm = reinterpret_cast<int16*>(Bytes.GetData());
		for (int32 I = 0; I < Samples.Num(); ++I) Pcm[I] = static_cast<int16>(FMath::Clamp(Samples[I], -1.0f, 1.0f) * 32767.0f);
		return Bytes;
	}

	bool SaveStereoWav(const FString& Path, const TArray<float>& Left, const TArray<float>& Right, int32 SampleRate)
	{
		const int32 Frames = FMath::Min(Left.Num(), Right.Num()); TArray<uint8> Data; Data.Reserve(Frames * 4);
		for (int32 I = 0; I < Frames; ++I) { const int16 L = static_cast<int16>(FMath::Clamp(Left[I], -1.0f, 1.0f) * 32767.0f); const int16 R = static_cast<int16>(FMath::Clamp(Right[I], -1.0f, 1.0f) * 32767.0f); Data.Append(reinterpret_cast<const uint8*>(&L), 2); Data.Append(reinterpret_cast<const uint8*>(&R), 2); }
		TArray<uint8> Wav; FMemoryWriter Writer(Wav); auto FourCC = [&Writer](const char* S){ Writer.Serialize(const_cast<char*>(S), 4); };
		const uint32 RiffSize = 36 + Data.Num(), FmtSize = 16, ByteRate = SampleRate * 4; const uint16 Format = 1, Channels = 2, BlockAlign = 4, Bits = 16; const uint32 DataSize = Data.Num();
		FourCC("RIFF"); Writer << const_cast<uint32&>(RiffSize); FourCC("WAVE"); FourCC("fmt "); Writer << const_cast<uint32&>(FmtSize); Writer << const_cast<uint16&>(Format); Writer << const_cast<uint16&>(Channels); Writer << SampleRate; Writer << const_cast<uint32&>(ByteRate); Writer << const_cast<uint16&>(BlockAlign); Writer << const_cast<uint16&>(Bits); FourCC("data"); Writer << const_cast<uint32&>(DataSize); Writer.Serialize(Data.GetData(), Data.Num());
		return FFileHelper::SaveArrayToFile(Wav, *Path);
	}

	FVector AtAzimuth(float Degrees, float Radius = 400.0f)
	{
		const float Radians = FMath::DegreesToRadians(Degrees); return FVector(FMath::Cos(Radians) * Radius, FMath::Sin(Radians) * Radius, 80.0f);
	}
}

class FMixedAudioSubmixListener final : public ISubmixBufferListener
{
public:
	void Start(int32 CapacityFrames)
	{
		FScopeLock Lock(&Mutex); Capacity = CapacityFrames; Ring.SetNumZeroed(Capacity * 2); TotalFrames = 0; SampleRate = 0; NumChannels = 0; bRunning = true;
	}
	void Stop() { FScopeLock Lock(&Mutex); bRunning = false; }
	bool State(int32& OutRate, int64& OutFrames) const { FScopeLock Lock(&Mutex); OutRate = SampleRate; OutFrames = TotalFrames; return bRunning && SampleRate > 0 && NumChannels >= 2; }
	bool Read(int64 Start, int32 Count, TArray<float>& Left, TArray<float>& Right) const
	{
		FScopeLock Lock(&Mutex); if (!bRunning || Start < FMath::Max<int64>(0, TotalFrames - Capacity) || Start + Count > TotalFrames) return false;
		Left.SetNumUninitialized(Count); Right.SetNumUninitialized(Count);
		for (int32 I = 0; I < Count; ++I) { const int32 Offset = static_cast<int32>((Start + I) % Capacity) * 2; Left[I] = Ring[Offset]; Right[I] = Ring[Offset + 1]; }
		return true;
	}
	virtual void OnNewSubmixBuffer(const USoundSubmix*, float* AudioData, int32 NumSamples, int32 InChannels, const int32 InRate, double) override
	{
		FScopeLock Lock(&Mutex); if (!bRunning || !AudioData || InChannels < 2 || InRate <= 0) return; NumChannels = InChannels; SampleRate = InRate; const int32 Frames = NumSamples / InChannels;
		for (int32 I = 0; I < Frames; ++I) { const int32 Offset = static_cast<int32>((TotalFrames + I) % Capacity) * 2; Ring[Offset] = AudioData[I * InChannels]; Ring[Offset + 1] = AudioData[I * InChannels + 1]; } TotalFrames += Frames;
	}
	virtual const FString& GetListenerName() const override { static const FString Name(TEXT("MixedAudioAttentionMainOutput")); return Name; }
private:
	mutable FCriticalSection Mutex; TArray<float> Ring; int32 Capacity = 0; int32 SampleRate = 0; int32 NumChannels = 0; int64 TotalFrames = 0; bool bRunning = false;
};

AMixedAudioSource::AMixedAudioSource()
{
	PrimaryActorTick.bCanEverTick = true; SceneRoot = CreateDefaultSubobject<USceneComponent>(TEXT("Root")); SetRootComponent(SceneRoot);
	Visualizer = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("Visualizer")); Visualizer->SetupAttachment(SceneRoot); Visualizer->SetCollisionEnabled(ECollisionEnabled::NoCollision); Visualizer->SetRelativeScale3D(FVector(0.25f));
	static ConstructorHelpers::FObjectFinder<UStaticMesh> Sphere(TEXT("/Engine/BasicShapes/Sphere.Sphere")); if (Sphere.Succeeded()) Visualizer->SetStaticMesh(Sphere.Object);
	static ConstructorHelpers::FObjectFinder<UMaterialInterface> Material(TEXT("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial")); if (Material.Succeeded()) Visualizer->SetMaterial(0, Material.Object);
	ActivationTrigger = CreateDefaultSubobject<USphereComponent>(TEXT("ActivationTrigger")); ActivationTrigger->SetupAttachment(SceneRoot); ActivationTrigger->SetSphereRadius(100.0f); ActivationTrigger->SetCollisionEnabled(ECollisionEnabled::QueryOnly); ActivationTrigger->SetCollisionObjectType(ECC_WorldDynamic); ActivationTrigger->SetCollisionResponseToAllChannels(ECR_Ignore); ActivationTrigger->SetCollisionResponseToChannel(ECC_Pawn, ECR_Overlap); ActivationTrigger->SetGenerateOverlapEvents(true); ActivationTrigger->OnComponentBeginOverlap.AddDynamic(this, &AMixedAudioSource::OnActivationBeginOverlap);
	Label = CreateDefaultSubobject<UTextRenderComponent>(TEXT("SourceLabel")); Label->SetupAttachment(SceneRoot); Label->SetRelativeLocation(FVector(0.0f, 0.0f, 58.0f)); Label->SetHorizontalAlignment(EHTA_Center); Label->SetVerticalAlignment(EVRTA_TextCenter); Label->SetWorldSize(14.0f); Label->SetTextRenderColor(FColor::White); Label->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	AudioComponent = CreateDefaultSubobject<UAudioComponent>(TEXT("Audio")); AudioComponent->SetupAttachment(SceneRoot); AudioComponent->bAutoActivate = false; AudioComponent->bAllowSpatialization = true;
	AudioComponent->SetOverrideAttenuation(true); FSoundAttenuationSettings Settings; Settings.bAttenuate = false; Settings.bSpatialize = true; Settings.SpatializationAlgorithm = ESoundSpatializationAlgorithm::SPATIALIZATION_HRTF; Settings.NonSpatializedRadiusStart = 0.0f; Settings.NonSpatializedRadiusEnd = 0.0f; AudioComponent->SetAttenuationOverrides(Settings);
}

void AMixedAudioSource::BeginPlay()
{
	Super::BeginPlay();
	if (UMaterialInterface* BaseMaterial = Visualizer->GetMaterial(0))
	{
		VisualizerMaterial = UMaterialInstanceDynamic::Create(BaseMaterial, this);
		Visualizer->SetMaterial(0, VisualizerMaterial);
	}
	UpdateVisualizerState();
}

void AMixedAudioSource::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (Label)
	{
		if (APlayerController* PC = UGameplayStatics::GetPlayerController(this, 0))
		{
			FVector CameraLocation;
			FRotator CameraRotation;
			PC->GetPlayerViewPoint(CameraLocation, CameraRotation);
			Label->SetWorldRotation((CameraLocation - Label->GetComponentLocation()).Rotation());
		}
	}
}

void AMixedAudioSource::ConfigureContinuous(int32 Seed, float Volume, bool bHighBand, float DurationSeconds)
{
	Kind = EMixedAudioSourceKind::Ambient; bSourceEnabled = true;
	constexpr int32 Rate = 48000; FRandomStream Random(Seed); TArray<float> Samples; Samples.SetNumUninitialized(Rate); float State = 0.0f;
	for (int32 I = 0; I < Rate; ++I) { const float Noise = Random.FRandRange(-1.0f, 1.0f); State = bHighBand ? Noise - 0.92f * State : 0.985f * State + 0.015f * Noise; Samples[I] = 0.35f * State; }
	const TArray<uint8> OneSecondPcm = ToPcm16(Samples); ProceduralWave = NewObject<USoundWaveProcedural>(this); ProceduralWave->SetSampleRate(Rate); ProceduralWave->NumChannels = 1; ProceduralWave->Duration = DurationSeconds; ProceduralWave->bLooping = false; ProceduralWave->VirtualizationMode = EVirtualizationMode::PlayWhenSilent; ProceduralWave->SoundGroup = SOUNDGROUP_Default;
	for (int32 Second = 0; Second < FMath::CeilToInt(DurationSeconds); ++Second) ProceduralWave->QueueAudio(OneSecondPcm.GetData(), OneSecondPcm.Num());
	AudioComponent->SetVolumeMultiplier(Volume); AudioComponent->SetSound(ProceduralWave); AudioComponent->Play(); UpdateVisualizerState();
}

void AMixedAudioSource::ConfigureBurst(bool bInitiallyEnabled)
{
	Kind = EMixedAudioSourceKind::Burst;
	SetSourceEnabled(bInitiallyEnabled);
}

bool AMixedAudioSource::Emit(const TArray<float>& Samples, int32 SampleRate, float Volume)
{
	if (Kind != EMixedAudioSourceKind::Burst || !bSourceEnabled) return false;
	USoundWaveProcedural* Wave = NewObject<USoundWaveProcedural>(this); Wave->SetSampleRate(SampleRate); Wave->NumChannels = 1; Wave->Duration = static_cast<float>(Samples.Num()) / SampleRate; Wave->SoundGroup = SOUNDGROUP_Default; TArray<uint8> Bytes = ToPcm16(Samples); Wave->QueueAudio(Bytes.GetData(), Bytes.Num());
	ProceduralWave = Wave; AudioComponent->Stop(); AudioComponent->SetVolumeMultiplier(Volume); AudioComponent->SetSound(Wave); AudioComponent->Play();
	return true;
}
void AMixedAudioSource::StopSource() { if (AudioComponent) AudioComponent->Stop(); }

void AMixedAudioSource::OnActivationBeginOverlap(
	UPrimitiveComponent*, AActor* OtherActor, UPrimitiveComponent*, int32, bool, const FHitResult&)
{
	if (!Cast<APawn>(OtherActor)) return;
	const double Now = FPlatformTime::Seconds();
	if (Now - LastToggleSeconds < 0.5) return;
	LastToggleSeconds = Now;
	SetSourceEnabled(!bSourceEnabled);
}

void AMixedAudioSource::SetSourceEnabled(bool bEnabled)
{
	bSourceEnabled = bEnabled;
	if (AudioComponent)
	{
		if (Kind == EMixedAudioSourceKind::Ambient) AudioComponent->SetPaused(!bSourceEnabled);
		else if (!bSourceEnabled) AudioComponent->Stop();
	}
	UpdateVisualizerState();
	UE_LOG(LogMixedAudioAttention, Display, TEXT("MIXED_AUDIO_SOURCE_TOGGLE source=%s kind=%s enabled=%s"), *GetName(), Kind == EMixedAudioSourceKind::Ambient ? TEXT("ambient") : TEXT("burst"), bSourceEnabled ? TEXT("true") : TEXT("false"));
}

void AMixedAudioSource::UpdateVisualizerState()
{
	const bool bAmbient = Kind == EMixedAudioSourceKind::Ambient;
	const FLinearColor TypeColor = bAmbient ? FLinearColor(0.02f, 0.75f, 1.0f) : FLinearColor(1.0f, 0.28f, 0.02f);
	const FLinearColor DisplayColor = bSourceEnabled ? TypeColor : FLinearColor(0.08f, 0.09f, 0.11f);
	if (VisualizerMaterial) VisualizerMaterial->SetVectorParameterValue(TEXT("Color"), DisplayColor);
	if (Visualizer) Visualizer->SetRelativeScale3D(FVector((bAmbient ? 0.38f : 0.24f) * (bSourceEnabled ? 1.12f : 1.0f)));
	if (Label)
	{
		Label->SetText(FText::FromString(FString::Printf(TEXT("%s  %s"), bAmbient ? TEXT("ENV") : TEXT("BURST"), bSourceEnabled ? TEXT("ON") : TEXT("OFF"))));
		Label->SetTextRenderColor(bSourceEnabled ? TypeColor.ToFColor(true) : FColor(110, 110, 110));
	}
}

AMixedAudioAttentionExperiment::AMixedAudioAttentionExperiment()
{
	PrimaryActorTick.bCanEverTick = true; SceneRoot = CreateDefaultSubobject<USceneComponent>(TEXT("Root")); SetRootComponent(SceneRoot);
}

void AMixedAudioAttentionExperiment::BeginPlay()
{
	Super::BeginPlay(); bFullExperiment = FParse::Param(FCommandLine::Get(), TEXT("MixedAudioFull")); PreviousVolumeMultiplier = FApp::GetVolumeMultiplier(); bPreviousUseVrFocus = FApp::UseVRFocus(); bPreviousHasVrFocus = FApp::HasVRFocus(); FApp::SetUseVRFocus(true); FApp::SetHasVRFocus(true); FApp::SetVolumeMultiplier(1.0f); if (GEngine) { bPreviousPauseOnLossOfFocus = GEngine->bPauseOnLossOfFocus; GEngine->bPauseOnLossOfFocus = false; }
	for (int32 I = 0; I < 2; ++I) { AMixedAudioSource* Source = GetWorld()->SpawnActor<AMixedAudioSource>(GetActorLocation() + AtAzimuth(I == 0 ? -60.0f : 60.0f, 300.0f), FRotator::ZeroRotator); Source->ConfigureContinuous(1000 + I, 0.18f, I == 1, bFullExperiment ? 720.0f : 120.0f); Sources.Add(Source); }
	for (const float Azimuth : {-120.0f, -60.0f, 60.0f, 120.0f}) { AMixedAudioSource* Source = GetWorld()->SpawnActor<AMixedAudioSource>(GetActorLocation() + AtAzimuth(Azimuth, 500.0f), FRotator::ZeroRotator); Source->ConfigureBurst(bFullExperiment); Sources.Add(Source); }
	if (!RegisterSubmixListener()) { UE_LOG(LogMixedAudioAttention, Error, TEXT("MIXED_AUDIO_CAPTURE_FAILED")); return; }
	Analyzer = MakeUnique<FMixedAudioAnalyzer>(48000, bFullExperiment ? 60.0f : 5.0f); Analyzer->Start();
	GetWorldTimerManager().SetTimer(EventTimer, this, &AMixedAudioAttentionExperiment::EmitDemoEvent, 2.0f, true, bFullExperiment ? 360.0f : 6.0f);
	UE_LOG(LogMixedAudioAttention, Display, TEXT("MIXED_AUDIO_READY mode=%s sources=%d"), bFullExperiment ? TEXT("full") : TEXT("demo"), Sources.Num());
}

bool AMixedAudioAttentionExperiment::RegisterSubmixListener()
{
	if (!GetWorld()) return false; FAudioDeviceHandle Handle = GetWorld()->GetAudioDevice(); if (!Handle.IsValid()) return false;
	SubmixListener = MakeShared<FMixedAudioSubmixListener, ESPMode::ThreadSafe>(); SubmixListener->Start(48000 * 5); Handle->RegisterSubmixBufferListener(SubmixListener.ToSharedRef(), Handle->GetMainSubmixObject()); return true;
}

void AMixedAudioAttentionExperiment::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds); PullCapturedAudio(); if (!Analyzer) return; FMixedAudioLiveSnapshot Live; FMixedAudioEventSnapshot Event; Analyzer->GetSnapshots(Live, Event); if (Live.StreamFrame >= NextDiagnosticFrame) { NextDiagnosticFrame = Live.StreamFrame + 96000; UE_LOG(LogMixedAudioAttention, Display, TEXT("MIXED_AUDIO_STREAM frame=%lld left_rms=%.6f right_rms=%.6f score=%.3f threshold=%.3f prediction=%s"), Live.StreamFrame, Live.LeftRms, Live.RightRms, Live.DetectorScoreDb, Live.DetectorThresholdDb, *Live.Prediction); } if (Event.bValid && Event.DetectionFrame != LastSavedDetectionFrame) { LastSavedDetectionFrame = Event.DetectionFrame; SaveEvent(Event); }
}

void AMixedAudioAttentionExperiment::PullCapturedAudio()
{
	if (!SubmixListener || !Analyzer) return; int32 Rate = 0; int64 Total = 0; if (!SubmixListener->State(Rate, Total) || Rate != 48000) return;
	constexpr int32 Block = 480; int32 Count = 0; while (NextReadFrame + Block <= Total && Count++ < 64) { TArray<float> Left, Right; if (!SubmixListener->Read(NextReadFrame, Block, Left, Right)) { NextReadFrame = FMath::Max<int64>(0, Total - 48000 * 4); continue; } Analyzer->PushStereo(NextReadFrame, MoveTemp(Left), MoveTemp(Right)); NextReadFrame += Block; }
}

void AMixedAudioAttentionExperiment::EmitDemoEvent()
{
	if (!Analyzer || Sources.Num() < 6) return; static const float Angles[] = {-120, -60, 60, 120}; static const float Snrs[] = {12, 6, 0, -6}; const int32 Direction = EventIndex % 4; const bool bNoise = (EventIndex / 4) % 2 != 0; const float Snr = Snrs[(EventIndex / 8) % 4]; FString Truth = TEXT("Unknown"); FVector ListenerLocation, ListenerForward, ListenerRight; if (APlayerController* PC = UGameplayStatics::GetPlayerController(this, 0)) { PC->GetAudioListenerPosition(ListenerLocation, ListenerForward, ListenerRight); const float Side = FVector::DotProduct((Sources[2 + Direction]->GetActorLocation() - ListenerLocation).GetSafeNormal(), ListenerRight); if (Side < -0.02f) Truth = TEXT("Left"); else if (Side > 0.02f) Truth = TEXT("Right"); }
	const TArray<float> Signal = bNoise ? MixedAudioSignal::GenerateNoiseBurst(48000, 0.040f, 2000 + EventIndex) : MixedAudioSignal::GenerateChirp(48000, 0.040f, 500.0f, 4000.0f);
	if (Sources[2 + Direction]->Emit(Signal, 48000, 0.10f * FMath::Pow(10.0f, Snr / 20.0f)))
	{
		Analyzer->SetExpectedEvent(NextReadFrame, Truth);
		UE_LOG(LogMixedAudioAttention, Display, TEXT("MIXED_AUDIO_EVENT index=%d type=%s azimuth=%.0f snr=%.0f truth=%s frame=%lld"), EventIndex, bNoise ? TEXT("noise") : TEXT("chirp"), static_cast<double>(Angles[Direction]), static_cast<double>(Snr), *Truth, NextReadFrame);
	}
	else UE_LOG(LogMixedAudioAttention, Verbose, TEXT("MIXED_AUDIO_EVENT_SKIPPED index=%d azimuth=%.0f source_off=true"), EventIndex, static_cast<double>(Angles[Direction]));
	++EventIndex;
	if (bFullExperiment && EventIndex >= 160) { GetWorldTimerManager().ClearTimer(EventTimer); SaveSummary(); UE_LOG(LogMixedAudioAttention, Display, TEXT("MIXED_AUDIO_FULL_EVENTS_COMPLETE count=%d"), EventIndex); }
}

int32 AMixedAudioAttentionExperiment::GetActiveSourceCount() const
{
	int32 Count = 0;
	for (const AMixedAudioSource* Source : Sources) if (Source && Source->IsSourceEnabled()) ++Count;
	return Count;
}

void AMixedAudioAttentionExperiment::GetSnapshots(FMixedAudioLiveSnapshot& OutLive, FMixedAudioEventSnapshot& OutEvent) const
{
	if (Analyzer) Analyzer->GetSnapshots(OutLive, OutEvent);
	if (APlayerController* PC = UGameplayStatics::GetPlayerController(this, 0)) { FVector Forward, Right; PC->GetAudioListenerPosition(OutLive.ListenerLocation, Forward, Right); OutLive.ListenerYaw = FMath::RadiansToDegrees(FMath::Atan2(Forward.Y, Forward.X)); }
}

void AMixedAudioAttentionExperiment::SaveEvent(const FMixedAudioEventSnapshot& Event)
{
	const FString Directory = FPaths::ProjectSavedDir() / TEXT("MixedAudioAttention"); IFileManager::Get().MakeDirectory(*Directory, true); const FString Prefix = FString::Printf(TEXT("event-%04d"), SavedEventCount++);
	SaveStereoWav(Directory / (Prefix + TEXT("-raw.wav")), Event.RawLeft, Event.RawRight, 48000); SaveStereoWav(Directory / (Prefix + TEXT("-extracted.wav")), Event.ExtractedLeft, Event.ExtractedRight, 48000);
	TSharedRef<FJsonObject> Record = MakeShared<FJsonObject>(); Record->SetStringField(TEXT("prefix"), Prefix); Record->SetNumberField(TEXT("detection_frame"), Event.DetectionFrame); Record->SetStringField(TEXT("truth"), Event.Truth); Record->SetStringField(TEXT("prediction"), Event.Prediction); Record->SetNumberField(TEXT("confidence"), Event.Confidence); Record->SetNumberField(TEXT("latency_ms"), Event.LatencyMs); Record->SetNumberField(TEXT("lag_samples"), Event.LagSamples); Record->SetNumberField(TEXT("ild_db"), Event.IldDb); Record->SetField(TEXT("raw_si_sdr_db"), MakeShared<FJsonValueNull>()); Record->SetField(TEXT("extracted_si_sdr_db"), MakeShared<FJsonValueNull>()); EventRecords.Add(MakeShared<FJsonValueObject>(Record)); SaveSummary();
}

void AMixedAudioAttentionExperiment::SaveSummary()
{
	FMixedAudioLiveSnapshot Live; FMixedAudioEventSnapshot Event; GetSnapshots(Live, Event); TSharedRef<FJsonObject> Root = MakeShared<FJsonObject>(); Root->SetStringField(TEXT("engine"), FEngineVersion::Current().ToString()); Root->SetStringField(TEXT("mode"), bFullExperiment ? TEXT("full") : TEXT("demo")); Root->SetNumberField(TEXT("sample_rate"), 48000); Root->SetNumberField(TEXT("fft_size"), 1024); Root->SetNumberField(TEXT("hop_size"), 480); Root->SetNumberField(TEXT("saved_events"), SavedEventCount); Root->SetNumberField(TEXT("stream_frame"), Live.StreamFrame); Root->SetNumberField(TEXT("worker_backlog"), Live.WorkerBacklog); Root->SetNumberField(TEXT("queue_overruns"), Live.QueueOverruns); Root->SetStringField(TEXT("latest_prediction"), Event.Prediction); Root->SetStringField(TEXT("latest_truth"), Event.Truth); Root->SetNumberField(TEXT("latest_confidence"), Event.Confidence); Root->SetNumberField(TEXT("latest_latency_ms"), Event.LatencyMs); Root->SetArrayField(TEXT("events"), EventRecords); Root->SetStringField(TEXT("note"), TEXT("Demo output; full 60 s calibration + 300 s negative evaluation requires -MixedAudioFull.")); FString Json; TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Json); FJsonSerializer::Serialize(Root, Writer); const FString Directory = FPaths::ProjectSavedDir() / TEXT("MixedAudioAttention"); IFileManager::Get().MakeDirectory(*Directory, true); FFileHelper::SaveStringToFile(Json, *(Directory / TEXT("run.json")));
}

void AMixedAudioAttentionExperiment::EndPlay(const EEndPlayReason::Type Reason)
{
	GetWorldTimerManager().ClearTimer(EventTimer); for (AMixedAudioSource* Source : Sources) if (Source) Source->StopSource(); if (Analyzer) { Analyzer->StopAnalyzer(); Analyzer.Reset(); }
	if (SubmixListener && GetWorld()) { FAudioDeviceHandle Handle = GetWorld()->GetAudioDevice(); if (Handle.IsValid()) Handle->UnregisterSubmixBufferListener(SubmixListener.ToSharedRef(), Handle->GetMainSubmixObject()); SubmixListener->Stop(); SubmixListener.Reset(); }
	FApp::SetVolumeMultiplier(PreviousVolumeMultiplier); FApp::SetHasVRFocus(bPreviousHasVrFocus); FApp::SetUseVRFocus(bPreviousUseVrFocus); if (GEngine) GEngine->bPauseOnLossOfFocus = bPreviousPauseOnLossOfFocus; Super::EndPlay(Reason);
}
