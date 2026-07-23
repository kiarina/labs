#!/usr/bin/env python3

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results" / "pie-results.json"
RENDERED_RESULTS = ROOT / "results" / "rendered-results.json"
UNFOCUSED_FAILURE = ROOT / "results" / "rendered-unfocused-failure.json"
FOCUS_CONTROL = ROOT / "results" / "rendered-focus-control-summary.json"
HRTF_RESULTS = ROOT / "results" / "hrtf-results-summary.json"
CONTINUOUS_RESULTS = ROOT / "results" / "continuous-hrtf-results-summary.json"
MOTION_RESULTS = ROOT / "results" / "avatar-listener-motion-summary.json"
INTERACTIVE_RESULTS = ROOT / "results" / "interactive-hud-summary.json"
SOURCE = ROOT / "project" / "Source" / "AudioLocalization" / "AudioLocalizationExperiment.cpp"
HUD_SOURCE = ROOT / "project" / "Source" / "AudioLocalization" / "AudioLocalizationHUD.cpp"
GAME_MODE_SOURCE = ROOT / "project" / "Source" / "AudioLocalization" / "AudioLocalizationGameMode.cpp"


def main() -> None:
    report = json.loads(RESULTS.read_text())
    trials = report["trials"]

    assert report["source_count"] == 10
    assert report["trials_per_source"] == 5
    assert report["evaluated_trials"] == 50
    assert report["correct_trials"] == 50
    assert report["unknown_trials"] == 0
    assert report["accuracy"] >= 0.95
    assert len(trials) == 50
    assert all(trial["correct"] for trial in trials)
    assert {trial["prediction"] for trial in trials} == {"Left", "Right"}
    assert min(trial["correlation"] for trial in trials) >= 0.99

    rendered = json.loads(RENDERED_RESULTS.read_text())
    rendered_trials = rendered["trials"]
    assert rendered["experiment_mode"] == "rendered_main_output_submix"
    assert rendered["evaluated_trials"] == 50
    assert rendered["correct_trials"] == 50
    assert rendered["unknown_trials"] == 0
    assert rendered["accuracy"] >= 0.95
    assert len(rendered_trials) == 50
    assert all(trial["captured"] for trial in rendered_trials)
    assert all(trial["rendered_sample_rate"] == 48000 for trial in rendered_trials)
    assert all(trial["rendered_channels"] == 2 for trial in rendered_trials)
    assert all(trial["active_frames"] > 0 for trial in rendered_trials)
    assert all(trial["lag_samples"] == 0 for trial in rendered_trials)
    assert all(
        (trial["ild_db"] > 0) == (trial["ground_truth"] == "Left")
        for trial in rendered_trials
    )

    failed = json.loads(UNFOCUSED_FAILURE.read_text())
    failed_trials = failed["trials"]
    assert failed["correct_trials"] == 0
    assert failed["unknown_trials"] == 50
    assert all(trial["captured"] for trial in failed_trials)
    assert all(trial["active_frames"] == 0 for trial in failed_trials)

    control = json.loads(FOCUS_CONTROL.read_text())
    control_result = control["last_attempt"]
    assert control_result["app_had_focus_at_begin"] is False
    assert control_result["app_volume_multiplier_before_override"] == 0
    assert control_result["force_audio_when_unfocused"] is False
    assert control_result["captured_trials"] == 50
    assert control_result["nonzero_active_trials"] == 0
    assert control_result["unknown_trials"] == 50

    hrtf = json.loads(HRTF_RESULTS.read_text())
    assert hrtf["experiment_mode"] == "hrtf_main_output_submix"
    assert hrtf["active_spatialization_plugin"] == "Resonance Audio"
    assert hrtf["quality_mode"] == "BINAURAL_HIGH"
    assert hrtf["app_has_focus_after_override"] is True
    assert hrtf["correct_trials"] == 50
    assert hrtf["unknown_trials"] == 0
    assert len(hrtf["by_azimuth"]) == 10
    assert all(
        row["prediction"] == row["ground_truth"] for row in hrtf["by_azimuth"]
    )
    assert all(
        (row["ild_db_mean"] > 0) == (row["ground_truth"] == "Left")
        for row in hrtf["by_azimuth"]
    )

    continuous = json.loads(CONTINUOUS_RESULTS.read_text())
    assert continuous["experiment_mode"] == "continuous_hrtf_stream"
    assert continuous["active_spatialization_plugin"] == "Resonance Audio"
    assert continuous["analysis_window_ms"] == 30
    assert continuous["analysis_hop_ms"] == 15
    assert continuous["expected_events"] == 10
    assert continuous["matched_events"] == 10
    assert continuous["missed_events"] == 0
    assert continuous["detections"] == 10
    assert continuous["false_positives"] == 0
    assert continuous["event_recall"] == 1.0
    assert continuous["event_precision"] == 1.0
    assert continuous["side_accuracy"] == 0.9
    assert len(continuous["by_azimuth"]) == 10

    motion = json.loads(MOTION_RESULTS.read_text())
    assert motion["listener_placement"] == "avatar_pawn_view_location"
    assert motion["validation_avatar_motion_applied"] is True
    assert motion["before_motion_listener_cm"]["x"] == 0
    assert motion["after_motion_listener_cm"]["x"] == 100
    assert motion["matched_events"] == 10
    assert motion["false_positives"] == 0
    assert all(
        row["nominal_degrees"] != row["after_motion_degrees"]
        for row in motion["azimuth_changes"]
    )

    interactive = json.loads(INTERACTIVE_RESULTS.read_text())
    assert interactive["experiment_mode"] == "interactive_hrtf_stream"
    assert interactive["source_count"] == 10
    assert interactive["source_interaction"]["method"] == "pawn_capsule_begin_overlap_toggle"
    assert interactive["validation"]["contact_on_observed"] is True
    assert interactive["validation"]["contact_off_observed"] is True
    assert interactive["validation"]["repeating_on_observed"] is True
    assert interactive["validation"]["repeating_off_observed"] is True
    assert interactive["validation"]["material_parameter_transition_observed"] is True
    assert interactive["source_interaction"]["material_instance"] == "per_source_dynamic"
    assert interactive["validation"]["hud_received_nonzero_pcm"] is True
    assert interactive["validation"]["hud_left_samples"] == 9600
    assert interactive["validation"]["hud_right_samples"] == 9600
    assert interactive["default_validation_contact_enabled"] is False

    code = SOURCE.read_text()
    classifier = code.split(
        "AudioLocalizationSignal::FEstimate AudioLocalizationSignal::EstimateSide", 1
    )[1].split("AAudioLocalizationPulseSource::AAudioLocalizationPulseSource", 1)[0]
    assert "SourceLocation" not in classifier
    assert "FVector" not in classifier
    assert "Left" in classifier and "Right" in classifier
    assert "ISubmixBufferListener" in code
    assert "OnNewSubmixBuffer" in code
    assert "GetMainSubmixObject" in code
    assert "bForceAudioWhenUnfocused" in code
    assert "FApp::HasFocus" in code
    assert "SPATIALIZATION_HRTF" in code
    assert 'TEXT("Resonance Audio")' in code
    assert "SetUseVRFocus(true)" in code
    assert "StartStreaming" in code
    assert "ReadStereoFrames" in code
    assert "AnalyzeContinuousStream" in code
    assert "bPauseOnLossOfFocus = false" in code
    assert "SetAudioListenerOverride" in code
    assert "ClearAudioListenerOverride" in code
    assert 'TEXT("avatar_pawn_view_location")' in code
    assert "OnActivationTriggerBeginOverlap" in code
    assert "SetRepeating(!bRepeating)" in code
    assert "BasicShapeMaterial.BasicShapeMaterial" in code
    assert "UMaterialInstanceDynamic::Create" in code
    assert "Visualizer->SetMaterial(0, VisualizerMaterial)" in code
    assert "SetVectorParameterValueOnMaterials" not in code
    assert "UpdateVisualizationSnapshot" in code

    hud_code = HUD_SOURCE.read_text()
    assert 'TEXT("LEFT EAR")' in hud_code
    assert 'TEXT("RIGHT EAR")' in hud_code
    assert "WaveformFullScaleAmplitude" in hud_code
    assert "Snapshot.LeftRms" in hud_code and "Snapshot.RightRms" in hud_code
    assert "AUDIO_LOCALIZATION_HUD_READY" in hud_code
    assert "AAudioLocalizationHUD::StaticClass()" in GAME_MODE_SOURCE.read_text()

    print(
        "PASS: geometry 50/50, rendered Submix 50/50, "
        "HRTF 50/50, continuous events 10/10 with 0 false positives, "
        "avatar listener motion 100 cm verified, "
        "interactive source on/off and stereo HUD verified, "
        "unfocused-silence control preserved, waveform-only classifier"
    )


if __name__ == "__main__":
    main()
