## Runtime load (Seed-san)

| run | fixes | status | where it stopped |
|---|---|---|---|
| upstream-game-load | 00 | crashed | UAnimBlueprint::SetPreviewMesh(USkeletalMesh*, bool) |
| upstream-pie-load | 00 | crashed | UAnimBlueprint::SetPreviewMesh(USkeletalMesh*, bool) |
| fix02-game-load | 00+02 | crashed | UEditorEngine::BeginTransaction(FText const&) |
| fix01+02-game-load | 00+01+02 | ok | loaded in 0.87 s |

## Editor import (ImportVRMFileWithOptions)

| run | status | post-process ABP | morph targets |
|---|---|---|---|
| upstream-import | ok | /Game/ImportCheck/ABP_Post_Seed-san.ABP_Post_Seed-san_C | 43 |
| fix01+02-import | ok | /Game/ImportCheck/ABP_Post_Seed-san.ABP_Post_Seed-san_C | 43 |

## PIE load time vs. components in the world

| fixes | filler components | load_seconds (trial 1, 2) |
|---|---|---|
| 00+02 | 0 | 0.613, 0.592 |
| 00+02 | 2000 | 1.467, 1.484 |
| 00+02+03 | 0 | 0.560, 0.561 |
| 00+02+03 | 2000 | 0.563, 0.570 |

## PIE screenshots (AA off)

- fix02-pie-shot-1.png vs fix02-pie-shot-2.png: size=(407, 593) max_channel_diff=0 pixels_over_8=0 (0.000%)
- fix02+03-pie-shot-1.png vs fix02+03-pie-shot-2.png: size=(407, 593) max_channel_diff=1 pixels_over_8=0 (0.000%)
- fix02-pie-shot-1.png vs fix02+03-pie-shot-1.png: size=(407, 593) max_channel_diff=0 pixels_over_8=0 (0.000%)

## Spring response (PIE, gravity/wind/colliders off, 150 cm/s along +X)

| model | spring | joints | tail offset X during cruise: 00+02 | 00+02+04 |
|---|---|---|---|---|
| Seed-san | hair_tail_1 | 7 | -14.46 cm | -16.18 cm |
| Seed-san | hair_A_001 | 2 | -2.33 cm | -2.51 cm |
| Seed-san | robo_wire | 7 | -36.96 cm | -38.40 cm |
| Seed-san-thinned | hair_tail_1 | 4 | -0.00 cm | -13.53 cm |
| Seed-san-thinned | hair_A_001 | 2 | -2.33 cm | -2.51 cm |
| Seed-san-thinned | robo_wire | 4 | 0.00 cm | -29.20 cm |

Rest pose with the character still (same run): max joint rotation from the authored rest pose
- Seed-san: 00+02 0.01 deg, 00+02+04 0.01 deg
- Seed-san-thinned: 00+02 0.01 deg, 00+02+04 0.01 deg
