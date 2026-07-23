// Copyright Epic Games, Inc. All Rights Reserved.

#include "AudioLocalizationHUD.h"

#include "AudioLocalization.h"
#include "AudioLocalizationExperiment.h"
#include "Engine/Canvas.h"
#include "Engine/Engine.h"
#include "EngineUtils.h"

AAudioLocalizationExperiment* AAudioLocalizationHUD::FindExperiment()
{
	if (Experiment.IsValid())
	{
		return Experiment.Get();
	}
	TActorIterator<AAudioLocalizationExperiment> It(GetWorld());
	if (It)
	{
		Experiment = *It;
		return *It;
	}
	return nullptr;
}

void AAudioLocalizationHUD::DrawHUD()
{
	Super::DrawHUD();
	if (!Canvas)
	{
		return;
	}

	AAudioLocalizationExperiment* ExperimentActor = FindExperiment();
	if (!ExperimentActor)
	{
		return;
	}

	FAudioLocalizationVisualizationSnapshot Snapshot;
	ExperimentActor->GetVisualizationSnapshot(Snapshot);
	if (!bLoggedReady && Snapshot.bStreamReady &&
		!Snapshot.LeftWaveform.IsEmpty() && !Snapshot.RightWaveform.IsEmpty() &&
		(Snapshot.LeftRms > 1.0e-6f || Snapshot.RightRms > 1.0e-6f))
	{
		bLoggedReady = true;
		UE_LOG(LogAudioLocalization, Display,
			TEXT("AUDIO_LOCALIZATION_HUD_READY left_samples=%d right_samples=%d left_rms=%.6f right_rms=%.6f active_sources=%d"),
			Snapshot.LeftWaveform.Num(), Snapshot.RightWaveform.Num(),
			static_cast<double>(Snapshot.LeftRms), static_cast<double>(Snapshot.RightRms),
			Snapshot.ActiveSourceCount);
	}
	const float Margin = 28.0f;
	const float Gap = 28.0f;
	const float PanelWidth = FMath::Clamp(
		(Canvas->SizeX - Margin * 2.0f - Gap) * 0.5f, 240.0f, 520.0f);
	const float PanelHeight = 170.0f;
	const float PanelY = Canvas->SizeY - PanelHeight - Margin;
	const float LeftX = Margin;
	const float RightX = Canvas->SizeX - Margin - PanelWidth;

	DrawWaveformPanel(
		TEXT("LEFT EAR"), Snapshot.LeftWaveform, Snapshot.LeftRms,
		FLinearColor(0.10f, 0.85f, 1.0f, 1.0f),
		LeftX, PanelY, PanelWidth, PanelHeight);
	DrawWaveformPanel(
		TEXT("RIGHT EAR"), Snapshot.RightWaveform, Snapshot.RightRms,
		FLinearColor(1.0f, 0.48f, 0.08f, 1.0f),
		RightX, PanelY, PanelWidth, PanelHeight);

	const FString Status = FString::Printf(
		TEXT("HRTF %s   SOURCES ON %d   PREDICTION %s   LAG %d   ILD %+.2f dB   CORR %.2f"),
		Snapshot.bStreamReady ? TEXT("STREAMING") : TEXT("WAITING"),
		Snapshot.ActiveSourceCount,
		*Snapshot.Prediction,
		Snapshot.LagSamples,
		static_cast<double>(Snapshot.IldDb),
		static_cast<double>(Snapshot.Correlation));
	DrawText(
		Status,
		FLinearColor::White,
		Margin,
		PanelY - 28.0f,
		GEngine ? GEngine->GetSmallFont() : nullptr,
		1.0f,
		false);
}

void AAudioLocalizationHUD::DrawWaveformPanel(
	const FString& Label,
	const TArray<float>& Samples,
	float Rms,
	const FLinearColor& Color,
	float X,
	float Y,
	float Width,
	float Height)
{
	DrawRect(FLinearColor(0.01f, 0.015f, 0.025f, 0.78f), X, Y, Width, Height);
	DrawText(
		FString::Printf(TEXT("%s   RMS %.5f"), *Label, static_cast<double>(Rms)),
		Color,
		X + 12.0f,
		Y + 8.0f,
		GEngine ? GEngine->GetSmallFont() : nullptr,
		1.0f,
		false);

	const float GraphX = X + 10.0f;
	const float GraphY = Y + 36.0f;
	const float GraphWidth = Width - 20.0f;
	const float GraphHeight = Height - 48.0f;
	const float CenterY = GraphY + GraphHeight * 0.5f;
	DrawLine(GraphX, CenterY, GraphX + GraphWidth, CenterY,
		FLinearColor(0.30f, 0.30f, 0.35f, 0.7f), 1.0f);

	if (Samples.IsEmpty())
	{
		return;
	}

	const int32 PixelColumns = FMath::Max(1, FMath::FloorToInt(GraphWidth));
	for (int32 Column = 0; Column < PixelColumns; ++Column)
	{
		const int32 StartIndex = Column * Samples.Num() / PixelColumns;
		const int32 EndIndex = FMath::Max(
			StartIndex + 1, (Column + 1) * Samples.Num() / PixelColumns);
		float Minimum = 0.0f;
		float Maximum = 0.0f;
		for (int32 Index = StartIndex; Index < EndIndex && Index < Samples.Num(); ++Index)
		{
			Minimum = FMath::Min(Minimum, Samples[Index]);
			Maximum = FMath::Max(Maximum, Samples[Index]);
		}
		const float Scale = GraphHeight * 0.5f / FMath::Max(1.0e-6f, WaveformFullScaleAmplitude);
		const float Top = CenterY - FMath::Clamp(Maximum * Scale, -GraphHeight * 0.5f, GraphHeight * 0.5f);
		const float Bottom = CenterY - FMath::Clamp(Minimum * Scale, -GraphHeight * 0.5f, GraphHeight * 0.5f);
		const float DrawX = GraphX + Column;
		DrawLine(DrawX, Top, DrawX, Bottom, Color, 1.0f);
	}
}
