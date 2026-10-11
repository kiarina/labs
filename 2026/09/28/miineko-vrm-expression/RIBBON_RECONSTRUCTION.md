# Ribbon reconstruction checks

These lessons come from the accepted K production handoff. They apply to
local reconstruction of an existing skinned accessory, with the original face
and body preserved. [FINAL_2026_10_12.md](FINAL_2026_10_12.md) identifies the
private delivery and reproduction inputs; this document does not replace them.

## Tie every check to the delivered model

Capture every `isMesh` object, including mouth geometry, rather than filtering
by object name. The observed omission was caused by name-based selection, not
by mesh type. Tie all checks to one frozen saved VRM SHA-256; do not combine
passes from different candidates. Keep camera, lighting and expression fixed
for angle comparisons.

Evaluate self-intersection, motion interference and appearance separately.
Manifold topology does not imply absence of self-intersection: thinning the
back of the ribbon tails failed this check. Vertex ray parity alone misses
edge/face intersections and open skin. Use bidirectional edge/triangle checks,
part self-intersection, restoration-patch self/body checks and connection-gap
checks. The ordinary-pose zero-interference result concerns wings/tails against
the whole body; the knot intentionally contacts the chest at a fixed 3.5 mm
distance. Strong downward bending caused contact on an earlier version and
has not been rechecked on K.

## Diagnose shading before editing texture

Separate albedo, normals, metallic response, actual occlusion and intersection
using lit/unlit views with a fixed camera. Disabling the entire normal map can
remove useful folds along with the unwanted darkening.

For local texture repair, follow UV triangle membership and inspect overlapping
UVs and island edges in shared images. A rectangular mask alone can change an
unrelated surface. Preserve old/new pixel bytes and the mask: float feathering
alone can introduce a one-byte rounding difference. PNG optimization changes
file hashes even when decoded pixels remain equal; verify these separately.

## Reconstruct the body and attachment locally

The original bow remains fused when coordinates are welded despite its UV
splits. There is no rear chest surface beneath it, so simple separation and
movement leave a hole. Retain boundary positions and weights in the restoration
patch. After packing influences into four weights, repeat checks on the actual
exported model; the unreduced-weight result is not a delivery guarantee.

Moving the whole ribbon toward the chest embeds its lower and inner portions.
Fit it locally to chest curvature during poses. Preserving front XY coordinates
alone does not preserve the depth ordering of wings, knot and tails; inspect
renders. Lowering the whole ribbon by 20 mm to avoid strong poses was rejected
because of its appearance.

## Preserve acceptance limits and recovery inputs

Thinning the tails did not solve self-intersection. A thick back rim concealed
side-on background gaps but looked thick and still left rear-oblique gaps, so
that approach was stopped by the owner. K acceptance covers shortened
protrusions, thinness and chest fitting with the upper gap retained. Do not
expand this closure into unrequested zero-gap or physics work.

Keep essential numerical patches, geometry, input hashes and versions in a
minimal reproduction kit so recovery does not depend on a transient cloud
workspace. Large collections of trial images are unnecessary. Check raw VRM,
Blend and ZIP sizes; for ZIP use DEFLATE, verify CRC and compare extracted bytes.
A plain Blender export need not match a patched runtime VRM.

The reproduction ZIP has not been obtained locally or saved into this
repository during documentation closure. Recording these lessons is separate
from preserving and independently executing the reproduction code.
