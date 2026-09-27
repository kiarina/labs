# Mouth depth follow-up

The owner approved the improved front appearance of `mouth-vowels-flatstart`.
Keep its horizontal opening and eye treatment as the baseline. This follow-up
changes mouth depth only; it does not change the front-plane coordinates, UVs,
palette, expression weights or original Body.

## Methods and findings

The earlier affine support covered each entire vertical column. A vertex near
the bottom consequently inherited clearance needed by the protruding W ridge
above it. Fitting an affine depth field to each vertex's own range brings much
of the opening closer to the head while retaining linear VRM morph blending.

| Trial | Finding |
| --- | --- |
| `mouth-profile-vertex` | Shorter profile projection, but irregular depths and triangle/head intersections leave rough edges. |
| `mouth-profile-smooth` | Eight forward-only smoothing passes and 2.5 mm vertex clearance improve continuity, but sampled triangle interiors still penetrate by up to 2.85 mm. Vertex clearance alone is insufficient. |
| `mouth-profile-fitted` | Use 1 mm vertex clearance, eight smoothing passes, and forward correction from four barycentric samples per visible triangle at 38 states. Collapse unused narrow-vowel columns in all coordinates. Current comparison candidate. |

Without the last collapse constraint, vertices at the same X/Z but different
depths form horizontal colored shelves in narrow vowels. Each collapsed column
is pinned to one depth after correction, moving only forward. The generated
full-open shape is checked for these accidental shelves.

The correction is shared across all target keys, preserving the normalized
blend contract. Final zero-area column pins can affect the depth path of mixed
shapes, so a separate measurement samples the visible triangle centroids of the
saved blend at 23 states. It is not a continuous collision proof, and it is not
an independent rendering engine; the actual exported VRM is checked separately
in three-vrm.

## Results (2026-09-28)

Environment remains Blender 5.1.2, VRM Add-on 4.7.2, three 0.186.1 and three-vrm
3.5.5 on Apple Silicon macOS. Evidence is in
[results/mouth-profile-evaluation.json](results/mouth-profile-evaluation.json).

- Exported front-plane coordinates and UVs match the approved baseline exactly.
  In 25 front screenshots, at most six pixels differ by more than two channel
  levels. Depth changes can alter occlusion, so this is not complete image equality.
- All 20 closed-mouth states, six eye-region cases and 36 relaxed/blink cases
  remain pixel-identical to their approved baselines. All 30 flat-floor checks pass.
- The viewer captures 125 vowel states including both profiles, 45 aa states,
  six mixed examples and head attachment cases. No runtime errors or warnings.
- At full `aa`, median sampled visible clearance falls from 5.81 to 1.59 mm.
  At full `oh`, it falls from 6.40 to 2.92 mm. These are geometric samples, not
  perceived-quality scores.
- The final 23-state centroid sample has no behind-head samples; minimum
  clearance is 0.655 mm. The previous baseline had up to 1.31 mm of penetration
  in this newly added measurement, despite its prior visual checks passing.
- The maximum gap is **not** improved everywhere: full-aa maximum increases
  from 17.58 to 19.67 mm at isolated locations. Some mixed states also retain
  large gaps. Small profile ripples and a corner tip remain in narrow vowels.
  This is a useful depth comparison, not a finished conformal mouth or cavity.
- A separate rebuild produces an identical VRM. Blender reimport retains all
  five mouth presets and their texture bindings; that check does not certify
  round-trip shading or another runtime.

## Reproduce

Prepare `mouth-red-bound` and the saved `mouth-vowels-flatstart` viewer captures
with `MOUTH_FLAT_START=1 mise run vowel-probe`. Then, with the same tool paths as
[VOWELS.md](VOWELS.md):

```sh
mise run mouth-profile-probe
MOUTH_RUN=mouth-profile-repeat mise run mouth-profile-probe
```

The task builds the depth candidate, captures the exported VRM, checks binding
reimport, measures the saved surface and compares the front against the preserved
baseline. The no-mipmap mouth sampler from the flat-onset pipeline still applies.
Open `viewer.html?model=mouth-profile-fitted`; the earlier front-approved candidate
remains a separate choice. Do not overwrite it or equate front approval with
approval of the new profile, audio timing, or the complete production VRM.

## Small-opening depth and lip occlusion

The owner subsequently supported the profile improvement but pointed out a red
projection at `aa=.18`, viewed from the left profile. The new candidate is
`mouth-onset-recessed`; `mouth-profile-fitted` remains its comparison baseline.

The first attempt (`mouth-onset-depth`) moved only Basis toward the source face
while keeping all full targets fixed. It improved typical clearance, but the
maximum sampled forward gap at `aa=.18` remained 18.47 mm and the visible tip
persisted. Treating the original raised black lip as a surface the opening must
always cover was the wrong constraint for this small opening.

The revised builder samples the original BaseColor through the original UVs to
identify dark lip ink. At those neutral vertices, it estimates the underlying
face depth from two samples below the dark rim. Original black lips may then
occlude the opening. At non-ink triangle samples, 49 individual/mixed states
constrain retraction so the mouth does not create new holes in the pink face.
Only the Basis depth changes; the full target coordinates and front-plane
coordinates/UVs stay fixed. This is input-specific authoring, not general-purpose
material segmentation or an anatomical cavity.

The distinction between occlusion and unwanted penetration matters here. The
new source-ink-aware surface report records both separately. In 32 measured
states, no non-ink sample is behind the head; minimum non-ink clearance is
0.801 mm. Many samples behind the original black lip are deliberately hidden.
At `aa=.18`, maximum forward gap in the sampled mouth falls from 18.47 to
3.74 mm. The negative median in that state is dominated by intentionally hidden
lip samples and must not be presented as a clearance improvement metric.

The cost of keeping the original rim in front is visible in the front view:
small openings show a thicker black W rim and less red near its upper sides.
The flat lower edge remains. Front coordinates being identical therefore does
**not** mean the intermediate images are identical (up to 1,298 changed pixels
in the sampled front comparisons against the prior profile).

The composed full-target POSITION arrays agree exactly in the exported files.
In 25 full-open screenshots there are up to 12 differing edge pixels, despite
that coordinate equality; this is not a claim of pixel-identical full opening.
The comparator bounds affected area and mean difference and records the maximum
channel difference. The former maximum-channel-only assertion was too strict
for these sparse edge differences and was replaced without discarding them.
Closed-mouth, eye-region and relaxed/blink reference checks remain pixel-exact.
The viewer now captures 150 vowel states, 50 aa states and six mixtures, including
18% explicitly. Blender binding reimport and byte-identical rebuild both pass.

Evidence: [results/mouth-onset-depth-evaluation.json](results/mouth-onset-depth-evaluation.json).
All earlier full-open corner limitations remain because those targets are
preserved. Other models, renderers and audio-driven timing are still unverified.

```sh
MOUTH_ONSET_DEPTH=lip-occlusion mise run mouth-profile-probe
MOUTH_ONSET_DEPTH=lip-occlusion MOUTH_RUN=mouth-onset-recessed-repeat mise run mouth-profile-probe
```

Open `viewer.html?model=mouth-onset-recessed`; the default output is separate from
the prior profile and front baselines. `scripts/source_ink.py` samples source ink
for both construction and diagnostics. Avoid replacing its source-UV lookup
with a height-only rule: the source W ridge is irregular.
