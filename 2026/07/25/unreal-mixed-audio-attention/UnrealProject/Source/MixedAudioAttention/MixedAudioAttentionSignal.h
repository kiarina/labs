#pragma once

#include "CoreMinimal.h"
#include "HAL/Runnable.h"
#include "Containers/Queue.h"
#include "DSP/AlignedBuffer.h"

namespace Audio { class IFFTAlgorithm; }

struct FMixedAudioLiveSnapshot
{
	TArray<float> LeftWaveform;
	TArray<float> RightWaveform;
	TArray<float> LeftSpectrogram;
	TArray<float> RightSpectrogram;
	TArray<float> SelectedMask;
	int32 SpectrogramColumns = 0;
	int32 SpectrogramBins = 0;
	int64 StreamFrame = 0;
	float DetectorScoreDb = 0.0f;
	float DetectorThresholdDb = 6.0f;
	float Confidence = 0.0f;
	float IldDb = 0.0f;
	float LeftRms = 0.0f;
	float RightRms = 0.0f;
	float LatencyMs = 0.0f;
	FVector ListenerLocation = FVector::ZeroVector;
	float ListenerYaw = 0.0f;
	int32 LagSamples = 0;
	int32 WorkerBacklog = 0;
	int32 QueueOverruns = 0;
	FString Prediction = TEXT("Unknown");
	bool bCalibrating = true;
};

struct FMixedAudioEventSnapshot
{
	TArray<float> RawLeft;
	TArray<float> RawRight;
	TArray<float> ExtractedLeft;
	TArray<float> ExtractedRight;
	TArray<float> Mask;
	int32 MaskColumns = 0;
	int32 MaskBins = 0;
	int32 OnsetSample = 0;
	int64 DetectionFrame = 0;
	float Confidence = 0.0f;
	float IldDb = 0.0f;
	float LatencyMs = 0.0f;
	float RawSiSdrDb = 0.0f;
	float ExtractedSiSdrDb = 0.0f;
	int32 LagSamples = 0;
	FString Truth = TEXT("Unmatched");
	FString Prediction = TEXT("Unknown");
	bool bValid = false;
};

namespace MixedAudioSignal
{
	struct FSideEstimate
	{
		FString Prediction = TEXT("Unknown");
		int32 LagSamples = 0;
		float IldDb = 0.0f;
		float Confidence = 0.0f;
	};

	MIXEDAUDIOATTENTION_API TArray<float> GenerateChirp(
		int32 SampleRate, float DurationSeconds, float StartHz, float EndHz);
	MIXEDAUDIOATTENTION_API TArray<float> GenerateNoiseBurst(
		int32 SampleRate, float DurationSeconds, int32 Seed);
	MIXEDAUDIOATTENTION_API FSideEstimate EstimateSideTimeDomain(
		const TArray<float>& Left, const TArray<float>& Right, int32 MaximumLagSamples);
	MIXEDAUDIOATTENTION_API float ComputeSiSdr(
		const TArray<float>& Estimate, const TArray<float>& Reference);
}

class FMixedAudioAnalyzer final : public FRunnable
{
public:
	FMixedAudioAnalyzer(int32 InSampleRate, float InCalibrationSeconds);
	virtual ~FMixedAudioAnalyzer() override;
	void Start();
	void StopAnalyzer();
	void PushStereo(int64 StartFrame, TArray<float>&& Left, TArray<float>&& Right);
	void SetExpectedEvent(int64 EmittedFrame, const FString& Truth);
	void GetSnapshots(FMixedAudioLiveSnapshot& OutLive, FMixedAudioEventSnapshot& OutEvent) const;
	virtual uint32 Run() override;
	virtual void Stop() override;

private:
	struct FBlock
	{
		int64 StartFrame = 0;
		TArray<float> Left;
		TArray<float> Right;
	};
	struct FExpected
	{
		int64 Frame = 0;
		FString Truth;
	};

	void ConsumeBlock(FBlock&& Block);
	void AnalyzeAvailable();
	void AnalyzeWindow(int64 StartFrame, const TArray<float>& Left, const TArray<float>& Right);
	void FinalizePendingEvent();
	void PublishLive();
	bool ReadHistory(int64 StartFrame, int32 NumFrames, TArray<float>& Left, TArray<float>& Right) const;

	static constexpr int32 FFTSize = 1024;
	static constexpr int32 HopSize = 480;
	static constexpr int32 DisplayBins = 96;
	static constexpr int32 DisplayColumns = 400;
	static constexpr int32 BandCount = 8;
	static constexpr int32 MaximumQueuedBlocks = 128;

	int32 SampleRate = 48000;
	int32 RingCapacity = 0;
	float CalibrationSeconds = 60.0f;
	TArray<float> RingLeft;
	TArray<float> RingRight;
	int64 TotalFrames = 0;
	int64 NextWindowFrame = 0;
	Audio::FAlignedFloatBuffer Window;
	Audio::FAlignedFloatBuffer LeftComplex;
	Audio::FAlignedFloatBuffer RightComplex;
	Audio::FAlignedFloatBuffer CrossComplex;
	Audio::FAlignedFloatBuffer Correlation;
	TArray<float> PreviousMagnitude;
	TArray<float> SlowBandDb;
	TArray<float> FastBandDb;
	TArray<float> CalibrationScores;
	TArray<float> SpectrogramLeft;
	TArray<float> SpectrogramRight;
	TArray<float> SpectrogramMask;
	int32 SpectrogramWriteColumn = 0;
	int64 LastDetectionFrame = MIN_int64;
	int64 PendingDetectionFrame = MIN_int64;
	FString PendingTruth = TEXT("Unmatched");
	FString PendingPrediction = TEXT("Unknown");
	float PendingConfidence = 0.0f;
	float PendingIldDb = 0.0f;
	int32 PendingLag = 0;
	float PendingLatencyMs = 0.0f;
	float CurrentScoreDb = 0.0f;
	float SlowRms = 0.0f;
	float ThresholdDb = 6.0f;
	float CurrentConfidence = 0.0f;
	float CurrentIldDb = 0.0f;
	float CurrentLatencyMs = 0.0f;
	int32 CurrentLag = 0;
	FString CurrentPrediction = TEXT("Unknown");
	FThreadSafeCounter PendingBlockCount;
	FThreadSafeCounter DroppedBlockCount;

	TUniquePtr<Audio::IFFTAlgorithm> FFT;
	FRunnableThread* Thread = nullptr;
	FEvent* WakeEvent = nullptr;
	FThreadSafeBool bStopRequested = false;
	TQueue<FBlock, EQueueMode::Mpsc> Queue;
	TQueue<FExpected, EQueueMode::Mpsc> ExpectedQueue;
	mutable FCriticalSection SnapshotMutex;
	FMixedAudioLiveSnapshot LiveSnapshot;
	FMixedAudioEventSnapshot EventSnapshot;
};
