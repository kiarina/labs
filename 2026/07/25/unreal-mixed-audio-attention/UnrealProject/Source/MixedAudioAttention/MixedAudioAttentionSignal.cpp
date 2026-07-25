#include "MixedAudioAttentionSignal.h"

#include "DSP/FFTAlgorithm.h"
#include "HAL/PlatformProcess.h"
#include "HAL/RunnableThread.h"
#include "Math/UnrealMathUtility.h"
#include "Misc/ScopeLock.h"
#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"
#endif

namespace
{
	constexpr float Epsilon = 1.0e-12f;

	float Rms(const TArray<float>& Values)
	{
		double Energy = 0.0;
		for (const float Value : Values) Energy += static_cast<double>(Value) * Value;
		return Values.IsEmpty() ? 0.0f : FMath::Sqrt(static_cast<float>(Energy / Values.Num()));
	}

	float Median(TArray<float> Values)
	{
		if (Values.IsEmpty()) return 0.0f;
		Values.Sort();
		const int32 Middle = Values.Num() / 2;
		return Values.Num() % 2 ? Values[Middle] : 0.5f * (Values[Middle - 1] + Values[Middle]);
	}

	float InverseScale(Audio::EFFTScaling Scaling, int32 Size)
	{
		switch (Scaling)
		{
		case Audio::EFFTScaling::MultipliedByFFTSize: return 1.0f / Size;
		case Audio::EFFTScaling::MultipliedBySqrtFFTSize: return 1.0f / FMath::Sqrt(static_cast<float>(Size));
		case Audio::EFFTScaling::DividedByFFTSize: return static_cast<float>(Size);
		case Audio::EFFTScaling::DividedBySqrtFFTSize: return FMath::Sqrt(static_cast<float>(Size));
		default: return 1.0f;
		}
	}
}

DEFINE_LOG_CATEGORY_STATIC(LogMixedAudioAnalyzer, Log, All);

TArray<float> MixedAudioSignal::GenerateChirp(int32 SampleRate, float DurationSeconds, float StartHz, float EndHz)
{
	const int32 Count = FMath::Max(1, FMath::RoundToInt(SampleRate * DurationSeconds));
	TArray<float> Result; Result.SetNumUninitialized(Count);
	for (int32 Index = 0; Index < Count; ++Index)
	{
		const float T = static_cast<float>(Index) / SampleRate;
		const float Alpha = static_cast<float>(Index) / FMath::Max(1, Count - 1);
		const float Phase = 2.0f * PI * (StartHz * T + 0.5f * (EndHz - StartHz) * T * Alpha);
		Result[Index] = 0.8f * (0.5f - 0.5f * FMath::Cos(2.0f * PI * Alpha)) * FMath::Sin(Phase);
	}
	return Result;
}

TArray<float> MixedAudioSignal::GenerateNoiseBurst(int32 SampleRate, float DurationSeconds, int32 Seed)
{
	const int32 Count = FMath::Max(1, FMath::RoundToInt(SampleRate * DurationSeconds));
	FRandomStream Random(Seed);
	TArray<float> Result; Result.SetNumUninitialized(Count);
	for (int32 Index = 0; Index < Count; ++Index)
	{
		const float Alpha = static_cast<float>(Index) / FMath::Max(1, Count - 1);
		Result[Index] = 0.65f * (0.5f - 0.5f * FMath::Cos(2.0f * PI * Alpha)) * Random.FRandRange(-1.0f, 1.0f);
	}
	return Result;
}

MixedAudioSignal::FSideEstimate MixedAudioSignal::EstimateSideTimeDomain(
	const TArray<float>& Left, const TArray<float>& Right, int32 MaximumLagSamples)
{
	FSideEstimate Result;
	if (Left.IsEmpty() || Left.Num() != Right.Num()) return Result;
	const float LeftRms = Rms(Left), RightRms = Rms(Right);
	Result.IldDb = 20.0f * FMath::LogX(10.0f, (LeftRms + Epsilon) / (RightRms + Epsilon));
	float Best = -1.0f;
	for (int32 Lag = -MaximumLagSamples; Lag <= MaximumLagSamples; ++Lag)
	{
		double Cross = 0.0, EL = 0.0, ER = 0.0;
		for (int32 L = 0; L < Left.Num(); ++L)
		{
			const int32 R = L + Lag; if (!Right.IsValidIndex(R)) continue;
			Cross += Left[L] * Right[R]; EL += Left[L] * Left[L]; ER += Right[R] * Right[R];
		}
		const float Corr = static_cast<float>(Cross / (FMath::Sqrt(EL * ER) + Epsilon));
		if (Corr > Best) { Best = Corr; Result.LagSamples = Lag; }
	}
	const float LagVote = Result.LagSamples == 0 ? 0.0f : FMath::Sign(static_cast<float>(Result.LagSamples));
	const float IldVote = FMath::Clamp(Result.IldDb / 6.0f, -1.0f, 1.0f);
	const float Vote = 0.6f * LagVote + 0.4f * IldVote;
	Result.Confidence = FMath::Abs(Vote);
	if (Result.Confidence >= 0.2f) Result.Prediction = Vote > 0.0f ? TEXT("Left") : TEXT("Right");
	return Result;
}

float MixedAudioSignal::ComputeSiSdr(const TArray<float>& Estimate, const TArray<float>& Reference)
{
	const int32 Count = FMath::Min(Estimate.Num(), Reference.Num());
	if (Count < 2) return 0.0f;
	double Dot = 0.0, ReferenceEnergy = 0.0;
	for (int32 I = 0; I < Count; ++I) { Dot += Estimate[I] * Reference[I]; ReferenceEnergy += Reference[I] * Reference[I]; }
	const double Scale = Dot / (ReferenceEnergy + Epsilon);
	double Target = 0.0, Noise = 0.0;
	for (int32 I = 0; I < Count; ++I) { const double T = Scale * Reference[I]; Target += T * T; const double N = Estimate[I] - T; Noise += N * N; }
	return 10.0f * FMath::LogX(10.0f, static_cast<float>((Target + Epsilon) / (Noise + Epsilon)));
}

FMixedAudioAnalyzer::FMixedAudioAnalyzer(int32 InSampleRate, float InCalibrationSeconds)
	: SampleRate(InSampleRate), RingCapacity(InSampleRate * 5), CalibrationSeconds(InCalibrationSeconds)
{
	RingLeft.SetNumZeroed(RingCapacity); RingRight.SetNumZeroed(RingCapacity);
	Window.SetNumUninitialized(FFTSize); LeftComplex.SetNumZeroed(FFTSize + 2); RightComplex.SetNumZeroed(FFTSize + 2);
	CrossComplex.SetNumZeroed(FFTSize + 2); Correlation.SetNumZeroed(FFTSize);
	PreviousMagnitude.SetNumZeroed(FFTSize / 2 + 1); SlowBandDb.Init(-120.0f, BandCount); FastBandDb.Init(-120.0f, BandCount);
	SpectrogramLeft.Init(-120.0f, DisplayColumns * DisplayBins); SpectrogramRight.Init(-120.0f, DisplayColumns * DisplayBins);
	SpectrogramMask.SetNumZeroed(DisplayColumns * DisplayBins);
	FFT = Audio::FFFTFactory::NewFFTAlgorithm({10, true, true});
	if (!FFT) UE_LOG(LogMixedAudioAnalyzer, Error, TEXT("MIXED_AUDIO_FFT_UNAVAILABLE size=%d"), FFTSize);
	WakeEvent = FPlatformProcess::GetSynchEventFromPool(false);
}

FMixedAudioAnalyzer::~FMixedAudioAnalyzer()
{
	StopAnalyzer();
	if (WakeEvent) { FPlatformProcess::ReturnSynchEventToPool(WakeEvent); WakeEvent = nullptr; }
}

void FMixedAudioAnalyzer::Start() { if (!Thread) Thread = FRunnableThread::Create(this, TEXT("MixedAudioAnalyzer")); }
void FMixedAudioAnalyzer::Stop() { bStopRequested = true; if (WakeEvent) WakeEvent->Trigger(); }
void FMixedAudioAnalyzer::StopAnalyzer() { Stop(); if (Thread) { Thread->WaitForCompletion(); delete Thread; Thread = nullptr; } }

void FMixedAudioAnalyzer::PushStereo(int64 StartFrame, TArray<float>&& Left, TArray<float>&& Right)
{
	if (Left.Num() != Right.Num() || Left.IsEmpty()) return;
	if (PendingBlockCount.GetValue() >= MaximumQueuedBlocks)
	{
		DroppedBlockCount.Increment();
		return;
	}
	PendingBlockCount.Increment();
	FBlock Block; Block.StartFrame = StartFrame; Block.Left = MoveTemp(Left); Block.Right = MoveTemp(Right); Queue.Enqueue(MoveTemp(Block));
	if (WakeEvent) WakeEvent->Trigger();
}

void FMixedAudioAnalyzer::SetExpectedEvent(int64 EmittedFrame, const FString& Truth)
{
	FExpected Expected; Expected.Frame = EmittedFrame; Expected.Truth = Truth; ExpectedQueue.Enqueue(MoveTemp(Expected));
}

void FMixedAudioAnalyzer::GetSnapshots(FMixedAudioLiveSnapshot& OutLive, FMixedAudioEventSnapshot& OutEvent) const
{
	FScopeLock Lock(&SnapshotMutex); OutLive = LiveSnapshot; OutEvent = EventSnapshot;
}

uint32 FMixedAudioAnalyzer::Run()
{
	while (!bStopRequested)
	{
		FBlock Block; bool bDidWork = false;
		while (Queue.Dequeue(Block)) { PendingBlockCount.Decrement(); ConsumeBlock(MoveTemp(Block)); bDidWork = true; }
		if (!bDidWork && WakeEvent) WakeEvent->Wait(20);
	}
	return 0;
}

void FMixedAudioAnalyzer::ConsumeBlock(FBlock&& Block)
{
	for (int32 I = 0; I < Block.Left.Num(); ++I)
	{
		const int64 Frame = Block.StartFrame + I; const int32 Ring = static_cast<int32>(Frame % RingCapacity);
		RingLeft[Ring] = Block.Left[I]; RingRight[Ring] = Block.Right[I];
	}
	TotalFrames = FMath::Max(TotalFrames, Block.StartFrame + Block.Left.Num());
	AnalyzeAvailable();
}

bool FMixedAudioAnalyzer::ReadHistory(int64 StartFrame, int32 NumFrames, TArray<float>& Left, TArray<float>& Right) const
{
	if (StartFrame < FMath::Max<int64>(0, TotalFrames - RingCapacity) || StartFrame + NumFrames > TotalFrames) return false;
	Left.SetNumUninitialized(NumFrames); Right.SetNumUninitialized(NumFrames);
	for (int32 I = 0; I < NumFrames; ++I) { const int32 Ring = static_cast<int32>((StartFrame + I) % RingCapacity); Left[I] = RingLeft[Ring]; Right[I] = RingRight[Ring]; }
	return true;
}

void FMixedAudioAnalyzer::AnalyzeAvailable()
{
	if (NextWindowFrame == 0 && TotalFrames >= FFTSize) NextWindowFrame = TotalFrames - FFTSize;
	while (NextWindowFrame + FFTSize <= TotalFrames)
	{
		TArray<float> Left, Right; if (!ReadHistory(NextWindowFrame, FFTSize, Left, Right)) { NextWindowFrame += HopSize; continue; }
		AnalyzeWindow(NextWindowFrame, Left, Right); NextWindowFrame += HopSize;
	}
	if (PendingDetectionFrame != MIN_int64 && TotalFrames >= PendingDetectionFrame + FMath::RoundToInt(0.75f * SampleRate)) FinalizePendingEvent();
	PublishLive();
}

void FMixedAudioAnalyzer::AnalyzeWindow(int64 StartFrame, const TArray<float>& Left, const TArray<float>& Right)
{
	if (!FFT) return;
	for (int32 DisplayBin = 0; DisplayBin < DisplayBins; ++DisplayBin)
	{
		const int32 Index = SpectrogramWriteColumn * DisplayBins + DisplayBin;
		SpectrogramLeft[Index] = -120.0f; SpectrogramRight[Index] = -120.0f; SpectrogramMask[Index] = 0.0f;
	}
	for (int32 I = 0; I < FFTSize; ++I) Window[I] = Left[I] * (0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)));
	FFT->ForwardRealToComplex(Window.GetData(), LeftComplex.GetData());
	for (int32 I = 0; I < FFTSize; ++I) Window[I] = Right[I] * (0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)));
	FFT->ForwardRealToComplex(Window.GetData(), RightComplex.GetData());

	TArray<float> BandDb; BandDb.Init(-120.0f, BandCount); TArray<float> BandEnergy; BandEnergy.Init(0.0f, BandCount);
	TArray<float> BinMagnitude; BinMagnitude.SetNumZeroed(FFTSize / 2 + 1);
	for (int32 Bin = 1; Bin <= FFTSize / 2; ++Bin)
	{
		const float LR = LeftComplex[2 * Bin], LI = LeftComplex[2 * Bin + 1], RR = RightComplex[2 * Bin], RI = RightComplex[2 * Bin + 1];
		const float Power = 0.5f * (LR * LR + LI * LI + RR * RR + RI * RI); BinMagnitude[Bin] = FMath::Sqrt(Power + Epsilon);
		const float Hz = static_cast<float>(Bin * SampleRate) / FFTSize;
		if (Hz >= 125.0f && Hz <= 8000.0f) { const int32 Band = FMath::Clamp(FMath::FloorToInt(FMath::Log2(Hz / 125.0f)), 0, BandCount - 1); BandEnergy[Band] += Power; }
	}
	float TopRise[3] = {0, 0, 0};
	for (int32 Band = 0; Band < BandCount; ++Band)
	{
		BandDb[Band] = 10.0f * FMath::LogX(10.0f, BandEnergy[Band] + Epsilon);
		if (SlowBandDb[Band] < -100.0f) SlowBandDb[Band] = FastBandDb[Band] = BandDb[Band];
		FastBandDb[Band] += 0.283f * (BandDb[Band] - FastBandDb[Band]); SlowBandDb[Band] += 0.00995f * (BandDb[Band] - SlowBandDb[Band]);
		const float Rise = FMath::Max(0.0f, FastBandDb[Band] - SlowBandDb[Band]);
		if (Rise > TopRise[0]) { TopRise[2] = TopRise[1]; TopRise[1] = TopRise[0]; TopRise[0] = Rise; } else if (Rise > TopRise[1]) { TopRise[2] = TopRise[1]; TopRise[1] = Rise; } else if (Rise > TopRise[2]) TopRise[2] = Rise;
	}
	const float CombinedRms = FMath::Sqrt(0.5f * (FMath::Square(Rms(Left)) + FMath::Square(Rms(Right))));
	if (SlowRms <= Epsilon) SlowRms = CombinedRms;
	const float RmsRiseDb = 20.0f * FMath::LogX(10.0f, (CombinedRms + Epsilon) / (SlowRms + Epsilon));
	SlowRms += 0.01f * (CombinedRms - SlowRms);
	CurrentScoreDb = FMath::Max(TopRise[0], RmsRiseDb);
	const float Elapsed = static_cast<float>(StartFrame + FFTSize) / SampleRate;
	if (Elapsed <= CalibrationSeconds) CalibrationScores.Add(CurrentScoreDb);
	else if (!CalibrationScores.IsEmpty())
	{
		const float Center = Median(CalibrationScores); TArray<float> Deviations; Deviations.Reserve(CalibrationScores.Num());
		for (float Value : CalibrationScores) Deviations.Add(FMath::Abs(Value - Center));
		ThresholdDb = FMath::Max(2.0f, Center + 6.0f * Median(MoveTemp(Deviations))); if (CalibrationSeconds < 10.0f) ThresholdDb = FMath::Min(ThresholdDb, 3.0f); CalibrationScores.Reset();
	}

	float IldNumerator = 0.0f, WeightSum = 0.0f;
	CrossComplex.Init(0.0f, FFTSize + 2);
	for (int32 Bin = 1; Bin <= FFTSize / 2; ++Bin)
	{
		const float Hz = static_cast<float>(Bin * SampleRate) / FFTSize;
		const float Rise = FMath::Max(0.0f, 20.0f * FMath::LogX(10.0f, (BinMagnitude[Bin] + Epsilon) / (PreviousMagnitude[Bin] + Epsilon)));
		const float Weight = FMath::Clamp(Rise / FMath::Max(ThresholdDb, 2.0f), 0.0f, 1.0f);
		PreviousMagnitude[Bin] = 0.9f * PreviousMagnitude[Bin] + 0.1f * BinMagnitude[Bin];
		const int32 DisplayBin = FMath::Clamp(FMath::FloorToInt(FMath::LogX(2.0f, Hz / 80.0f) / FMath::LogX(2.0f, 12000.0f / 80.0f) * DisplayBins), 0, DisplayBins - 1);
		if (Hz >= 80.0f && Hz <= 12000.0f)
		{
			const float LP = FMath::Square(LeftComplex[2 * Bin]) + FMath::Square(LeftComplex[2 * Bin + 1]); const float RP = FMath::Square(RightComplex[2 * Bin]) + FMath::Square(RightComplex[2 * Bin + 1]);
			SpectrogramLeft[SpectrogramWriteColumn * DisplayBins + DisplayBin] = FMath::Max(SpectrogramLeft[SpectrogramWriteColumn * DisplayBins + DisplayBin], 10.0f * FMath::LogX(10.0f, LP + Epsilon));
			SpectrogramRight[SpectrogramWriteColumn * DisplayBins + DisplayBin] = FMath::Max(SpectrogramRight[SpectrogramWriteColumn * DisplayBins + DisplayBin], 10.0f * FMath::LogX(10.0f, RP + Epsilon));
			SpectrogramMask[SpectrogramWriteColumn * DisplayBins + DisplayBin] = FMath::Max(SpectrogramMask[SpectrogramWriteColumn * DisplayBins + DisplayBin], Weight);
		}
		if (Hz >= 1500.0f && Hz <= 8000.0f && Weight > 0.1f)
		{
			const float LP = FMath::Square(LeftComplex[2 * Bin]) + FMath::Square(LeftComplex[2 * Bin + 1]); const float RP = FMath::Square(RightComplex[2 * Bin]) + FMath::Square(RightComplex[2 * Bin + 1]);
			IldNumerator += Weight * 10.0f * FMath::LogX(10.0f, (LP + Epsilon) / (RP + Epsilon)); WeightSum += Weight;
		}
		if (Hz >= 200.0f && Hz <= 1500.0f && Weight > 0.1f)
		{
			const float LR = LeftComplex[2 * Bin], LI = LeftComplex[2 * Bin + 1], RR = RightComplex[2 * Bin], RI = RightComplex[2 * Bin + 1];
			const float CR = LR * RR + LI * RI, CI = LI * RR - LR * RI, Norm = FMath::Sqrt(CR * CR + CI * CI) + Epsilon;
			CrossComplex[2 * Bin] = Weight * CR / Norm; CrossComplex[2 * Bin + 1] = Weight * CI / Norm;
		}
	}
	SpectrogramWriteColumn = (SpectrogramWriteColumn + 1) % DisplayColumns;
	FFT->InverseComplexToReal(CrossComplex.GetData(), Correlation.GetData()); const float Scale = InverseScale(FFT->InverseScaling(), FFTSize);
	float Best = -FLT_MAX; int32 BestLag = 0; constexpr int32 MaxLag = 28;
	for (int32 Lag = -MaxLag; Lag <= MaxLag; ++Lag) { const int32 Index = Lag >= 0 ? Lag : FFTSize + Lag; const float Value = Correlation[Index] * Scale; if (Value > Best) { Best = Value; BestLag = Lag; } }
	CurrentLag = -BestLag; CurrentIldDb = WeightSum > 0.0f ? IldNumerator / WeightSum : 0.0f;
	const float Vote = 0.6f * FMath::Sign(static_cast<float>(CurrentLag)) + 0.4f * FMath::Clamp(CurrentIldDb / 6.0f, -1.0f, 1.0f);
	CurrentConfidence = FMath::Abs(Vote); CurrentPrediction = CurrentConfidence >= 0.2f ? (Vote > 0.0f ? TEXT("Left") : TEXT("Right")) : TEXT("Unknown");

	const int64 DetectionFrame = StartFrame + FFTSize; const bool bOutsideRefractory = LastDetectionFrame == MIN_int64 || DetectionFrame - LastDetectionFrame >= FMath::RoundToInt64(0.15 * SampleRate);
	if (Elapsed > CalibrationSeconds && CurrentScoreDb >= ThresholdDb && bOutsideRefractory && PendingDetectionFrame == MIN_int64)
	{
		LastDetectionFrame = DetectionFrame; PendingDetectionFrame = DetectionFrame; PendingConfidence = CurrentConfidence; PendingIldDb = CurrentIldDb; PendingLag = CurrentLag; PendingTruth = TEXT("Unmatched"); PendingPrediction = CurrentPrediction; PendingLatencyMs = 0.0f;
		FExpected Expected; while (ExpectedQueue.Dequeue(Expected)) { const int64 Delay = DetectionFrame - Expected.Frame; if (Delay >= 0 && Delay <= SampleRate / 2) { PendingTruth = Expected.Truth; PendingLatencyMs = 1000.0f * Delay / SampleRate; } }
		CurrentLatencyMs = PendingLatencyMs;
		UE_LOG(LogMixedAudioAnalyzer, Display, TEXT("MIXED_AUDIO_DETECTION frame=%lld score=%.3f threshold=%.3f truth=%s prediction=%s confidence=%.3f lag=%d ild=%.3f latency_ms=%.3f"), DetectionFrame, CurrentScoreDb, ThresholdDb, *PendingTruth, *PendingPrediction, PendingConfidence, PendingLag, PendingIldDb, PendingLatencyMs);
	}
}

void FMixedAudioAnalyzer::FinalizePendingEvent()
{
	const int32 Pre = FMath::RoundToInt(0.25f * SampleRate), Total = SampleRate;
	TArray<float> Left, Right; if (!ReadHistory(PendingDetectionFrame - Pre, Total, Left, Right)) { PendingDetectionFrame = MIN_int64; return; }
	FMixedAudioEventSnapshot NewEvent; NewEvent.RawLeft = Left; NewEvent.RawRight = Right; NewEvent.ExtractedLeft.Init(0.0f, Total); NewEvent.ExtractedRight.Init(0.0f, Total);
	NewEvent.OnsetSample = Pre; NewEvent.DetectionFrame = PendingDetectionFrame; NewEvent.Truth = PendingTruth; NewEvent.Prediction = PendingPrediction;
	NewEvent.Confidence = PendingConfidence; NewEvent.IldDb = PendingIldDb; NewEvent.LagSamples = PendingLag; NewEvent.LatencyMs = PendingLatencyMs;
	NewEvent.MaskColumns = FMath::DivideAndRoundUp(Total - FFTSize, HopSize) + 1; NewEvent.MaskBins = DisplayBins; NewEvent.Mask.SetNumZeroed(NewEvent.MaskColumns * DisplayBins);
	TArray<float> Baseline; Baseline.Init(Epsilon, FFTSize / 2 + 1); int32 BaselineWindows = 0;
	for (int32 Start = 0; Start + FFTSize <= Pre; Start += HopSize)
	{
		for (int32 I = 0; I < FFTSize; ++I) Window[I] = 0.5f * (Left[Start + I] + Right[Start + I]) * (0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)));
		FFT->ForwardRealToComplex(Window.GetData(), LeftComplex.GetData());
		for (int32 Bin = 0; Bin <= FFTSize / 2; ++Bin) Baseline[Bin] += FMath::Sqrt(FMath::Square(LeftComplex[2 * Bin]) + FMath::Square(LeftComplex[2 * Bin + 1]));
		++BaselineWindows;
	}
	for (float& Value : Baseline) Value /= FMath::Max(1, BaselineWindows);
	TArray<float> Normalization; Normalization.Init(0.0f, Total); Audio::FAlignedFloatBuffer LeftOutput, RightOutput; LeftOutput.SetNumUninitialized(FFTSize); RightOutput.SetNumUninitialized(FFTSize);
	const float Inverse = InverseScale(FFT->InverseScaling(), FFTSize);
	for (int32 Column = 0, Start = 0; Start + FFTSize <= Total; Start += HopSize, ++Column)
	{
		for (int32 I = 0; I < FFTSize; ++I) Window[I] = Left[Start + I] * (0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)));
		FFT->ForwardRealToComplex(Window.GetData(), LeftComplex.GetData());
		for (int32 I = 0; I < FFTSize; ++I) Window[I] = Right[Start + I] * (0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)));
		FFT->ForwardRealToComplex(Window.GetData(), RightComplex.GetData());
		for (int32 Bin = 0; Bin <= FFTSize / 2; ++Bin)
		{
			const float LP = FMath::Square(LeftComplex[2 * Bin]) + FMath::Square(LeftComplex[2 * Bin + 1]), RP = FMath::Square(RightComplex[2 * Bin]) + FMath::Square(RightComplex[2 * Bin + 1]);
			const float Magnitude = FMath::Sqrt(0.5f * (LP + RP) + Epsilon); const float RiseDb = 20.0f * FMath::LogX(10.0f, (Magnitude + Epsilon) / (Baseline[Bin] + Epsilon));
			const float Salience = 1.0f / (1.0f + FMath::Exp(-(RiseDb - 3.0f) / 2.0f)); const float BinIld = 10.0f * FMath::LogX(10.0f, (LP + Epsilon) / (RP + Epsilon));
			const float SideArgument = PendingPrediction == TEXT("Left") ? BinIld : -BinIld; const float Side = PendingPrediction == TEXT("Unknown") ? 1.0f : 1.0f / (1.0f + FMath::Exp(-SideArgument / 3.0f)); const float Mask = FMath::Clamp(Salience * Side, 0.0f, 1.0f);
			LeftComplex[2 * Bin] *= Mask; LeftComplex[2 * Bin + 1] *= Mask; RightComplex[2 * Bin] *= Mask; RightComplex[2 * Bin + 1] *= Mask;
			const float Hz = static_cast<float>(Bin * SampleRate) / FFTSize; if (Hz >= 80.0f && Hz <= 12000.0f) { const int32 DisplayBin = FMath::Clamp(FMath::FloorToInt(FMath::LogX(2.0f, Hz / 80.0f) / FMath::LogX(2.0f, 150.0f) * DisplayBins), 0, DisplayBins - 1); NewEvent.Mask[Column * DisplayBins + DisplayBin] = FMath::Max(NewEvent.Mask[Column * DisplayBins + DisplayBin], Mask); }
		}
		FFT->InverseComplexToReal(LeftComplex.GetData(), LeftOutput.GetData()); FFT->InverseComplexToReal(RightComplex.GetData(), RightOutput.GetData());
		for (int32 I = 0; I < FFTSize; ++I) { const float Hann = 0.5f - 0.5f * FMath::Cos(2.0f * PI * I / (FFTSize - 1)); NewEvent.ExtractedLeft[Start + I] += LeftOutput[I] * Inverse * Hann; NewEvent.ExtractedRight[Start + I] += RightOutput[I] * Inverse * Hann; Normalization[Start + I] += Hann * Hann; }
	}
	for (int32 I = 0; I < Total; ++I) if (Normalization[I] > Epsilon) { NewEvent.ExtractedLeft[I] /= Normalization[I]; NewEvent.ExtractedRight[I] /= Normalization[I]; }
	NewEvent.bValid = true;
	{ FScopeLock Lock(&SnapshotMutex); EventSnapshot = MoveTemp(NewEvent); }
	PendingDetectionFrame = MIN_int64;
}

void FMixedAudioAnalyzer::PublishLive()
{
	FMixedAudioLiveSnapshot NewLive; const int32 WaveFrames = FMath::Min(RingCapacity, SampleRate * 2);
	ReadHistory(TotalFrames - WaveFrames, WaveFrames, NewLive.LeftWaveform, NewLive.RightWaveform);
	NewLive.LeftSpectrogram.SetNumUninitialized(DisplayColumns * DisplayBins); NewLive.RightSpectrogram.SetNumUninitialized(DisplayColumns * DisplayBins); NewLive.SelectedMask.SetNumUninitialized(DisplayColumns * DisplayBins);
	for (int32 X = 0; X < DisplayColumns; ++X) { const int32 SourceX = (SpectrogramWriteColumn + X) % DisplayColumns; for (int32 Y = 0; Y < DisplayBins; ++Y) { const int32 Source = SourceX * DisplayBins + Y, Destination = X * DisplayBins + Y; NewLive.LeftSpectrogram[Destination] = SpectrogramLeft[Source]; NewLive.RightSpectrogram[Destination] = SpectrogramRight[Source]; NewLive.SelectedMask[Destination] = SpectrogramMask[Source]; } }
	NewLive.SpectrogramColumns = DisplayColumns; NewLive.SpectrogramBins = DisplayBins; NewLive.StreamFrame = TotalFrames;
	NewLive.DetectorScoreDb = CurrentScoreDb; NewLive.DetectorThresholdDb = ThresholdDb; NewLive.Confidence = CurrentConfidence; NewLive.IldDb = CurrentIldDb;
	NewLive.LeftRms = Rms(NewLive.LeftWaveform); NewLive.RightRms = Rms(NewLive.RightWaveform);
	NewLive.LatencyMs = CurrentLatencyMs; NewLive.LagSamples = CurrentLag; NewLive.Prediction = CurrentPrediction; NewLive.bCalibrating = static_cast<float>(TotalFrames) / SampleRate <= CalibrationSeconds;
	NewLive.WorkerBacklog = PendingBlockCount.GetValue(); NewLive.QueueOverruns = DroppedBlockCount.GetValue();
	{ FScopeLock Lock(&SnapshotMutex); LiveSnapshot = MoveTemp(NewLive); }
}

#if WITH_DEV_AUTOMATION_TESTS

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FMixedAudioSignalTest,
	"MixedAudioAttention.Signal.GenerationAndSide",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FMixedAudioSignalTest::RunTest(const FString& Parameters)
{
	constexpr int32 Rate = 48000;
	const TArray<float> Chirp = MixedAudioSignal::GenerateChirp(Rate, 0.040f, 500.0f, 4000.0f);
	TestEqual(TEXT("40 ms chirp sample count"), Chirp.Num(), 1920);
	const TArray<float> NoiseA = MixedAudioSignal::GenerateNoiseBurst(Rate, 0.040f, 77);
	const TArray<float> NoiseB = MixedAudioSignal::GenerateNoiseBurst(Rate, 0.040f, 77);
	TestEqual(TEXT("Seeded noise is deterministic"), NoiseA, NoiseB);

	TArray<float> Left; Left.Init(0.0f, Chirp.Num() + 12); TArray<float> Right = Left;
	for (int32 I = 0; I < Chirp.Num(); ++I) { Left[I] = Chirp[I]; Right[I + 8] = 0.8f * Chirp[I]; }
	const MixedAudioSignal::FSideEstimate LeftEstimate = MixedAudioSignal::EstimateSideTimeDomain(Left, Right, 28);
	TestEqual(TEXT("Left-leading signal"), LeftEstimate.Prediction, FString(TEXT("Left")));
	TestTrue(TEXT("Left estimate is confident"), LeftEstimate.Confidence >= 0.2f);

	const MixedAudioSignal::FSideEstimate CenterEstimate = MixedAudioSignal::EstimateSideTimeDomain(Chirp, Chirp, 28);
	TestEqual(TEXT("Centered identical signal"), CenterEstimate.Prediction, FString(TEXT("Unknown")));
	TestTrue(TEXT("Identical SI-SDR is high"), MixedAudioSignal::ComputeSiSdr(Chirp, Chirp) > 80.0f);
	return true;
}

#endif
