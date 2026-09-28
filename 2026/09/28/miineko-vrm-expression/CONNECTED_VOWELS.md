# Connected vowels on one fixed face surface

## Scope

On 2026-09-29 the owner approved the [connected AA direction](CONNECTED_AA.md) as
closer to the sticker reference. This probe extends that mouth to five vowels.
It preserves the source pink head, protruding nose, original W and vertical stem.
The original black line is neither narrowed nor redrawn. The sticker remains a
reference, not an exact-match specification.

Open `vowel-study.html?variant=vowels&angle=0&opening=1&vowel=aa&response=early`.
Choose a vowel, use **ゆっくり開閉** for its onset, or **母音をつなぐ** for continuous
transitions. The comparison selector retains the accepted AA and revised normal
face. This is a new candidate: the other vowels and onset response are not yet
owner-approved. Audio and eye expressions are not restored in this model.

## Reproduce and verify

Prepare `feature-mouth-flush` and the accepted `mouth-connected-aa` artifacts via
[MOUTH_FLUSH.md](MOUTH_FLUSH.md) and [CONNECTED_AA.md](CONNECTED_AA.md). Use the
same pinned Blender, VRM add-on, Node and Python environments from [BASELINE.md](BASELINE.md).

```sh
BLENDER_BIN=/path/to/Blender COMPARE_PYTHON=.venv/bin/python mise run connected-vowels-probe
```

Outputs are `artifacts/mouth-connected-vowels` and `-repeat`; only those candidate
model directories are replaced. The shared builder's default AA mode still
reproduced the accepted AA hash exactly after this change:
`2284dd720e3df4428701b819cb4b794a0e345d291340465830938406768d4912`.
Images, models and detailed audits stay ignored/private. Reports under `results/`
contain numerical evidence only.

The question is whether distinct cartoon vowels and their mixtures can retain
source-W contact and fixed depth. Evaluation covers closed recovery at five
angles, pure/mixed weights, frontal contour connectivity, source-triangle audits,
standard VRM binding reimport, byte-identical regeneration, and responsive UI.
These checks do not establish final artistic quality or arbitrary-pose behavior.

## Method

The source-triangle clipper and ink mask are shared with AA. There is one added
surface and one unlit material, with no vertex motion or multiple overlapping
vowel layers. A 1024 × 4096 procedural texture encodes a quadratic reveal edge;
U changes its width and V changes its depth. Standard VRM texture-transform binds
supply both. The alpha mask still protects the original W from the red fill.
The original COLOR_1 → COLOR_0 exporter correction and non-mipmap LINEAR sampler
remain necessary.

For Blender coordinates, width `b=.074`, start `z0=.479`, and base rise `k0=.078`,
the untransformed UV is `u=.5+x/(4b)`, `v=.5+3(z-z0)`. At full vowel weight:

| Preset | Intended silhouette | Depth d | Rise k | U scale sqrt(k/k0) |
| --- | --- | ---: | ---: | ---: |
| aa | accepted rounded opening | .089 | .078 | 1.0000 |
| ih | shallow, wide | .058 | .031 | .6304 |
| ou | small, narrow | .072 | .170 | 1.4763 |
| ee | medium, wider | .070 | .060 | .8771 |
| oh | tall, narrow | .092 | .140 | 1.3397 |

The texture bind has scale `(s,1)` and glTF offset `((1-s)/2,-3d)`.
The resulting lower boundary is `z=z0-d+k(x/b)^2`. The nominal vertical rim
thickness stays .010, with the same .002 transition to red. These are authored
cartoon shapes, not anatomical phoneme reconstruction.

For normalized nonnegative weights with sum ≤ 1, transforms accumulate on this
single material. Effective depth is `sum(w*d)`, and effective rise is
`k0*(1+sum(w*(s-1)))^2`. Thus mixtures have one contour, though curvature is not
linear in the weights. Clipping uses a conservative envelope with maximum depth
and minimum rise so intermediate shapes fit as well as pure vowels. A union of
only the five endpoint outlines would not alone guarantee this.

The preview sanitizes weights and normalizes their sum. This is a driver
contract; VRM does not impose it on other consumers. Its optional **開き始めを早める**
response maps the opening control q to `q^0.6`, keeping 0 and 1 fixed. It is a
preview/driver adjustment, not encoded into the VRM or a claim of linear visible
area. The accepted-AA comparison uses its original raw response.

## Observations — 2026-09-29

- [Browser report](results/connected-vowels-evaluation.json): 125 pure-vowel
  states and 90 pair-mixture states, five exact closed-framebuffer matches,
  a complete five-vowel transition cycle, and 1280/600/390 px layouts pass.
  Separate builds produce byte-identical VRMs; original AA is unchanged.
- [Geometry report](results/connected-vowels-geometry.json): 23,548 added
  vertices, 40,310 triangles; parent-plane error ≤ 1.992e-8 model units and
  maximum nearest source-surface distance .000700002. Five standard texture
  binds reimport onto the same material; no vowel morph binds are needed.
- [Raster report](results/connected-vowels-contact.json): sampled frontal
  lower contours remain connected to the source W in each half, including
  mixtures. The upper face/nose region is pixel-identical. Pure-vowel red
  area grows monotonically across the sampled weights.
- Switching AA from the 1-D palette to the 2-D texture changes 268 pixels at
  full opening in the 900-pixel-wide frontal canvas (max channel difference
  35/255, mean absolute channel difference .000698/255). Its equation is the
  same, but filtering/tessellation do not give pixel-identical open contours.
  The accepted original remains available rather than being overwritten.
- The onset response helps, but does not remove the dead zone: at control .1,
  IH still has zero visible red pixels. At .25, it has 7. The thick source W
  hides small openings. Do not report this as solved or silently thin the W.

## Next work and limits

Reconnect the existing known-audio preview to these new shapes, then calibrate
opening strength and timing using this model's visible onset. Do not reuse old
amplitudes as if the old morph mouth and this reveal behaved identically.
Keep the raw/early comparison until the response is evaluated in speech.
The single-surface method avoids morph-induced depth drift, but current raster
checks are not all-view contact proofs. Source edge aliasing and ink-mask edges
remain visible in close side views. Head/neck motion with skinning, new eye
expressions, gaze, springs and other runtimes still require validation.
