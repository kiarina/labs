#include "MixedAudioAttentionHUD.h"

#include "MixedAudioAttentionExperiment.h"
#include "CanvasItem.h"
#include "Engine/Canvas.h"
#include "Engine/Engine.h"
#include "Engine/Texture2D.h"
#include "EngineUtils.h"
#include "GameFramework/PlayerController.h"
#include "InputCoreTypes.h"

namespace
{
	float CommonPeak(std::initializer_list<const TArray<float>*> Series)
	{
		float Peak = 0.01f;
		for (const TArray<float>* Values : Series) if (Values) for (const float Value : *Values) Peak = FMath::Max(Peak, FMath::Abs(Value));
		return Peak * 1.08f;
	}
}

AMixedAudioAttentionExperiment* AMixedAudioAttentionHUD::FindExperiment()
{
	if (Experiment.IsValid()) return Experiment.Get();
	TActorIterator<AMixedAudioAttentionExperiment> It(GetWorld());
	if (It) { Experiment = *It; return *It; }
	return nullptr;
}

void AMixedAudioAttentionHUD::EnsureTextures(int32 Width, int32 Height)
{
	if (LeftTexture && LeftTexture->GetSizeX() == Width && LeftTexture->GetSizeY() == Height) return;
	LeftTexture = UTexture2D::CreateTransient(Width, Height, PF_B8G8R8A8, TEXT("MixedAudioLeftSpectrogram"));
	RightTexture = UTexture2D::CreateTransient(Width, Height, PF_B8G8R8A8, TEXT("MixedAudioRightSpectrogram"));
	for (UTexture2D* Texture : {LeftTexture.Get(), RightTexture.Get()}) { Texture->Filter = TF_Nearest; Texture->SRGB = true; Texture->NeverStream = true; Texture->UpdateResource(); }
}

void AMixedAudioAttentionHUD::UpdateSpectrogramTexture(UTexture2D* Texture, const TArray<float>& Values, const TArray<float>& Mask, int32 Columns, int32 Bins, bool bLeft)
{
	if (!Texture || Values.Num() != Columns * Bins) return; uint8* Pixels = new uint8[Columns * Bins * 4];
	for (int32 X = 0; X < Columns; ++X) for (int32 Y = 0; Y < Bins; ++Y)
	{
		const int32 Source = X * Bins + Y, Destination = ((Bins - 1 - Y) * Columns + X) * 4; const float Level = FMath::Clamp((Values[Source] + 80.0f) / 80.0f, 0.0f, 1.0f); const bool bSelected = Mask.IsValidIndex(Source) && Mask[Source] > 0.35f;
		const FColor Base = bLeft ? FColor(8, static_cast<uint8>(30 + 115 * Level), static_cast<uint8>(45 + 165 * Level)) : FColor(static_cast<uint8>(45 + 165 * Level), static_cast<uint8>(22 + 80 * Level), 8);
		const FColor Color = bSelected ? FColor(190, 160, 25) : Base;
		Pixels[Destination] = Color.B; Pixels[Destination + 1] = Color.G; Pixels[Destination + 2] = Color.R; Pixels[Destination + 3] = 255;
	}
	FUpdateTextureRegion2D* Region = new FUpdateTextureRegion2D(0, 0, 0, 0, Columns, Bins);
	Texture->UpdateTextureRegions(0, 1, Region, Columns * 4, 4, Pixels, [](uint8* Data, const FUpdateTextureRegion2D* Regions){ delete[] Data; delete Regions; });
}

void AMixedAudioAttentionHUD::DrawWaveform(const TArray<float>& Samples, const TArray<float>* Overlay, const FLinearColor& Color, float X, float Y, float Width, float Height, float FullScale, int32 Onset)
{
	DrawRect(FLinearColor(0.01f, 0.015f, 0.025f, 0.90f), X, Y, Width, Height); const float Center = Y + Height * 0.5f; DrawLine(X, Center, X + Width, Center, FLinearColor(0.25f, 0.25f, 0.3f), 1.0f); if (Samples.IsEmpty()) return;
	auto DrawSeries = [&](const TArray<float>& Series, const FLinearColor& SeriesColor, float Thickness)
	{
		const int32 Pixels = FMath::Max(1, FMath::FloorToInt(Width)); const float AmplitudeScale = Height * 0.46f / FMath::Max(FullScale, 1.0e-6f); for (int32 Column = 0; Column < Pixels; ++Column) { const int32 Begin = Column * Series.Num() / Pixels, End = FMath::Max(Begin + 1, (Column + 1) * Series.Num() / Pixels); float Minimum = 0.0f, Maximum = 0.0f; for (int32 I = Begin; I < End && I < Series.Num(); ++I) { Minimum = FMath::Min(Minimum, Series[I]); Maximum = FMath::Max(Maximum, Series[I]); } const float Top = FMath::Clamp(Center - Maximum * AmplitudeScale, Y + 1.0f, Y + Height - 1.0f); const float Bottom = FMath::Clamp(Center - Minimum * AmplitudeScale, Y + 1.0f, Y + Height - 1.0f); DrawLine(X + Column, Top, X + Column, Bottom, SeriesColor, Thickness); }
	};
	DrawSeries(Samples, Color, 1.0f); if (Overlay && !Overlay->IsEmpty()) DrawSeries(*Overlay, FLinearColor::Yellow, 1.0f);
	if (Onset >= 0) { const float OnsetX = X + Width * static_cast<float>(Onset) / Samples.Num(); DrawLine(OnsetX, Y, OnsetX, Y + Height, FLinearColor::Red, 2.0f); }
}

void AMixedAudioAttentionHUD::DrawTexturePanel(UTexture2D* Texture, float X, float Y, float Width, float Height)
{
	DrawRect(FLinearColor(0.01f, 0.015f, 0.025f, 0.90f), X, Y, Width, Height); if (!Texture || !Texture->GetResource()) return; FCanvasTileItem Tile(FVector2D(X, Y), Texture->GetResource(), FVector2D(Width, Height), FLinearColor::White); Tile.BlendMode = SE_BLEND_Opaque; Canvas->DrawItem(Tile);
}

void AMixedAudioAttentionHUD::DrawHUD()
{
	Super::DrawHUD(); if (!Canvas) return; AMixedAudioAttentionExperiment* ExperimentActor = FindExperiment(); if (!ExperimentActor) return;
	FMixedAudioLiveSnapshot Live; FMixedAudioEventSnapshot Event; ExperimentActor->GetSnapshots(Live, Event);
	if (APlayerController* PC = GetOwningPlayerController(); PC && PC->WasInputKeyJustPressed(EKeys::H)) bDetailedView = !bDetailedView;
	if (Live.SpectrogramColumns > 0 && Live.StreamFrame != LastTextureFrame) { EnsureTextures(Live.SpectrogramColumns, Live.SpectrogramBins); UpdateSpectrogramTexture(LeftTexture, Live.LeftSpectrogram, Live.SelectedMask, Live.SpectrogramColumns, Live.SpectrogramBins, true); UpdateSpectrogramTexture(RightTexture, Live.RightSpectrogram, Live.SelectedMask, Live.SpectrogramColumns, Live.SpectrogramBins, false); LastTextureFrame = Live.StreamFrame; }
	const float Scale = FMath::Min(Canvas->SizeX / 1920.0f, Canvas->SizeY / 1080.0f), Margin = 24.0f * Scale, Gap = 20.0f * Scale, Width = (Canvas->SizeX - 2 * Margin - Gap) * 0.5f;
	DrawRect(FLinearColor(0.01f, 0.015f, 0.025f, 0.78f), Margin, Margin, Canvas->SizeX - 2.0f * Margin, 48.0f * Scale);
	const FString Status = FString::Printf(TEXT("%s  SOURCES %d/6  HEAD %.0f,%.0f,%.0f  YAW %.0f  PRED %s %.2f  LAT %.0f ms"), Live.bCalibrating ? TEXT("CALIBRATING") : TEXT("STREAMING"), ExperimentActor->GetActiveSourceCount(), Live.ListenerLocation.X, Live.ListenerLocation.Y, Live.ListenerLocation.Z, Live.ListenerYaw, *Live.Prediction, Live.Confidence, Live.LatencyMs);
	DrawText(Status, FLinearColor::White, Margin + 10.0f * Scale, Margin + 6.0f * Scale, GEngine ? GEngine->GetSmallFont() : nullptr, Scale, false);
	DrawText(FString::Printf(TEXT("score %.2f / %.2f dB   lag %d   ILD %+.2f dB   queue %d/%d   [H] %s"), Live.DetectorScoreDb, Live.DetectorThresholdDb, Live.LagSamples, Live.IldDb, Live.WorkerBacklog, Live.QueueOverruns, bDetailedView ? TEXT("compact") : TEXT("details")), FLinearColor(0.7f, 0.75f, 0.8f), Margin + 10.0f * Scale, Margin + 26.0f * Scale, GEngine ? GEngine->GetSmallFont() : nullptr, Scale, false);
	const float StreamPeak = CommonPeak({&Live.LeftWaveform, &Live.RightWaveform}); const float EventPeak = CommonPeak({&Event.RawLeft, &Event.RawRight, &Event.ExtractedLeft, &Event.ExtractedRight});
	if (!bDetailedView)
	{
		const float DockH = 238.0f * Scale, DockY = Canvas->SizeY - Margin - DockH, LabelH = 18.0f * Scale, WaveH = 48.0f * Scale, SpecH = 88.0f * Scale, EventH = 48.0f * Scale;
		DrawRect(FLinearColor(0.005f, 0.008f, 0.015f, 0.72f), Margin, DockY, Canvas->SizeX - 2.0f * Margin, DockH);
		DrawText(TEXT("LEFT EAR"), FLinearColor(0.1f, 0.85f, 1.0f), Margin + 8.0f * Scale, DockY + 4.0f * Scale, nullptr, Scale); DrawText(TEXT("RIGHT EAR"), FLinearColor(1.0f, 0.48f, 0.08f), Margin + Width + Gap + 8.0f * Scale, DockY + 4.0f * Scale, nullptr, Scale);
		const float WaveY = DockY + LabelH + 5.0f * Scale; DrawWaveform(Live.LeftWaveform, nullptr, FLinearColor(0.1f, 0.85f, 1.0f), Margin, WaveY, Width, WaveH, StreamPeak); DrawWaveform(Live.RightWaveform, nullptr, FLinearColor(1.0f, 0.48f, 0.08f), Margin + Width + Gap, WaveY, Width, WaveH, StreamPeak);
		const float SpecY = WaveY + WaveH + 5.0f * Scale; DrawTexturePanel(LeftTexture, Margin, SpecY, Width, SpecH); DrawTexturePanel(RightTexture, Margin + Width + Gap, SpecY, Width, SpecH);
		const float EventY = SpecY + SpecH + 5.0f * Scale; if (Event.bValid) { DrawWaveform(Event.RawLeft, &Event.ExtractedLeft, FLinearColor(0.38f, 0.4f, 0.45f), Margin, EventY, Width, EventH, EventPeak, Event.OnsetSample); DrawWaveform(Event.RawRight, &Event.ExtractedRight, FLinearColor(0.38f, 0.4f, 0.45f), Margin + Width + Gap, EventY, Width, EventH, EventPeak, Event.OnsetSample); }
		return;
	}
	const float WaveY = 90.0f * Scale, WaveH = 120.0f * Scale, SpecY = WaveY + WaveH + Gap, SpecH = 220.0f * Scale; DrawText(TEXT("LEFT STREAM / 2 s"), FLinearColor(0.1f, 0.85f, 1.0f), Margin, WaveY - 20 * Scale); DrawText(TEXT("RIGHT STREAM / 2 s"), FLinearColor(1.0f, 0.48f, 0.08f), Margin + Width + Gap, WaveY - 20 * Scale);
	DrawWaveform(Live.LeftWaveform, nullptr, FLinearColor(0.1f, 0.85f, 1.0f), Margin, WaveY, Width, WaveH, StreamPeak); DrawWaveform(Live.RightWaveform, nullptr, FLinearColor(1.0f, 0.48f, 0.08f), Margin + Width + Gap, WaveY, Width, WaveH, StreamPeak);
	DrawTexturePanel(LeftTexture, Margin, SpecY, Width, SpecH); DrawTexturePanel(RightTexture, Margin + Width + Gap, SpecY, Width, SpecH);
	const float EventY = SpecY + SpecH + 34.0f * Scale, EventH = 105.0f * Scale; if (Event.bValid) { DrawText(FString::Printf(TEXT("LATEST EVENT  TRUTH %s  PRED %s  CONF %.2f  LAT %.1f ms  RAW gray / EXTRACTED yellow"), *Event.Truth, *Event.Prediction, Event.Confidence, Event.LatencyMs), FLinearColor::White, Margin, EventY - 22 * Scale); DrawWaveform(Event.RawLeft, &Event.ExtractedLeft, FLinearColor(0.45f, 0.45f, 0.5f), Margin, EventY, Width, EventH, EventPeak, Event.OnsetSample); DrawWaveform(Event.RawRight, &Event.ExtractedRight, FLinearColor(0.45f, 0.45f, 0.5f), Margin + Width + Gap, EventY, Width, EventH, EventPeak, Event.OnsetSample); }
}
