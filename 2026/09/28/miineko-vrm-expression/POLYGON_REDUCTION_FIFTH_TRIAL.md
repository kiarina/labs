# Fifth reduction trial: quality-priority local retessellation

The owner requested an approximately 80,000-triangle prototype after accepting
motion in the [fourth experiment](POLYGON_REDUCTION_FOURTH_EXPERIMENT.md).
The conservative result is **94,770 triangles**, not 80,000. It saves 10,468
triangles (9.95%) versus v4 and 52.95% versus accepted K. Larger body reductions
were rejected after posed-surface and tangent-frame checks. This does not prove
that 80k is impossible; it is the best qualified branch of this local experiment.
K and all previous versions remain available.

| Metric | Accepted K | Fourth experiment | Fifth trial |
| --- | ---: | ---: | ---: |
| Triangles | 201,423 | 105,238 | 94,770 |
| VRM bytes | 20,954,188 | 17,693,552 | 17,630,744 |
| Stored unique POSITION records | — | 81,371 | 81,371 |

Images, image resolution and stored vertex records are unchanged. File size falls
only 62,808 bytes. Draw calls are not reduced and FPS is not measured.

## Changes and safeguards

Only body primitive 0 and six lid index buffers change. Body saves 1,242 triangles
(34,188 to 32,946 including unchanged eye primitives); lids save 9,226 (30,367 to
21,141). Mouth, chest repair and all ribbon indices remain exact to v4. Every
stored vertex/morph array, position bound, material, texture/image payload, rig,
expression and metadata item remains exact.

Retained vertex attributes alone do not guarantee unchanged interpolation after
retessellation. Separate source-domain overlays and posed-surface checks are
therefore required. Body preserves all 7,349 attribute-boundary edges and 22,564
protected semantic triangles, including eyes, ears and ear-morph support, nose,
mouth contours/joins and contact neighborhoods. A strictly interior black-mouth
branch uses unchanged uniformly black texture footprints with a two-pixel margin.

Independent body UV-overlay calculations reproduce maximum rest displacement
0.022203 mm and maximum among 12 tested posed fields 0.044682 mm. Normal bound is
0.468195 degrees; geometric/tangent/bitangent maxima remain below one degree.
A larger early donor reached 0.20068 mm posed error and was not adopted.

Lid source-sheet overlays retain boundaries, seams, folds and locally restored
visible-edge patches. Maximum checked depth error is 0.049906 mm and inward error
0.019949 mm. Affine position/UV/alpha/weight fields use overlay extrema; normalized
normal comparisons use finite probes, not a global angular guarantee. No error
limit was loosened to hit the count target.

Two draft native-identity bugs were caught before delivery: welding identical
source records changed inherited face identities, and two new corners referenced
rows unused after v4 pruning. The final layout retains literal original triples
for inherited faces and uses referenced, payload-identical records for new faces.
Regression fixtures reject both failures. Native source-corner provenance and
runtime drawstream preservation are independently verified.

## Compatibility and limits

This trial inherits v4's explicitly accepted shadow-sensitive tradeoff: some
hosts ignore vertex alpha in generated depth/shadow passes. It is not a universal
replacement for conservative v3. Default appearance is close, not pixel-identical,
because interpolated lid/body surfaces change. Tested samples cannot certify
arbitrary motion or every target application.

The editable Blend retains original vertices, shape keys, weights and native
corner data. Native versus runtime-corrected VRM differences remain at their
source levels. A normal GUI export is not promised to reproduce the final VRM.
The separate hash-checked runtime replay reconstructs the result from accepted K;
the native builder uses the v4 Blend and matching v4/runtime inputs.

## Final QA and recovery

The final SHA is fixed across 678 native-color frames: the established 78 standard
and 192 dense/motion frames, 369 additional blink views (nine directions × 41
weights), and 39 additional limb/ear motion captures. A separate 369 eye-visibility
mask set is not double-counted as native imagery. Standard/dense-face silhouettes
match; the established 270-image set has minimum silhouette IoU 0.99999616 from
one moving boundary. Bone/expression/UV state comparisons match, with no runtime
errors or nonfinite states.

The 369-view eye diagnostic flags at most three pixels per frame with baseline
<=16/candidate>32 thresholds. Independent equal-threshold (>32) analysis flags at
most eight. All are within one pixel of existing eye visibility; none are farther
than two pixels into a newly exposed interior. This distinguishes tiny edge
interpolation differences from an observed new hole, without claiming universal
closure or removing the original closed-eye slit appearance.

Explicit 34-condition shadow OFF and 34-condition forced-ON comparisons show small
but real differences in every pair. Maximum mean RGB difference is 0.00265/255 OFF
and 0.00638/255 ON; maximum channel differences are 89 and 100 in localized pixels.
Finite cloud-renderer tests do not establish every host's depth/outline/shadow
semantics. Contact neighborhoods match in 12 practical and 39 additional motion
poses; inherited intended knot embedding and upper/rear ribbon gaps remain.

Independent review recomputes body overlay extrema, checks final binary scope and
source identities, reopens the native companion in a fresh Blender process, and
replays accepted K to the final VRM byte-for-byte. Reproduction code and compact
reports are delivered separately; no model binaries or evidence screenshots are
added to Git.

The delivered reproduction ZIP was independently extracted: CRC and all 110
manifest hashes passed, and its extracted runtime replay reproduced the final
VRM SHA exactly. The kit includes compact reports and one meaningful worst-edge
comparison, not the full intermediate capture history.

| Item | Library reference | SHA-256 |
| --- | --- | --- |
| miineko-v5-shadow-sensitive-trial.vrm | `libfile_7a31bbf953488191aeee60197d26fb39` | `5cbc4c00b3b041771dedb56c18819e7b08185cbd4b2d5c9cfb52fead4c3f29d8` |
| miineko-v5-shadow-sensitive-trial.blend | `libfile_8c0d103cc4e081919ac22fbabbcedd89` | `60d46ff295ae2179b2211af941235d1301422ab046ee9ee221dad3b1faf99296` |
| miineko-v5-reproduction.zip | `libfile_273529c2356c8191836158859f8efb33` | `2b550aae264db3054c5168be4668b04a9381334e71ade3a117711b31cdda36ac` |
| miineko-v5-comparison.png | `libfile_033c48a7929c8191a19b72e76f53e90a` | `2040d6acdca31491170a7eb18d737dd1062aaa6da245ec13161a12eb40bf8427` |

Runtime replay requires accepted K VRM `libfile_f256f2e2fb00819190c434ca0fe5a7b1`
with SHA `01d01fc092cbdc1d4319761d71c86fff7b86f6864c83a0d98491713cda8f443a`.
Native reconstruction additionally needs the v4 source pair recorded in the
[fourth-experiment recovery table](POLYGON_REDUCTION_FOURTH_EXPERIMENT.md).
The new trial remains subject to the owner's target-application review; no
production asset replacement accompanies this record.
