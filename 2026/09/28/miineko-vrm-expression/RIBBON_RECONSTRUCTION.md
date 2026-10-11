# Ribbon reconstruction checks

These lessons come from the accepted K production handoff. They apply to
local reconstruction of an existing skinned accessory, with the original face
and body preserved. [FINAL_2026_10_12.md](FINAL_2026_10_12.md) identifies the
private delivery and reproduction inputs; this document does not replace them.

## Confirm what was actually tested

Capture every `isMesh` object rather than assuming an ordinary `Mesh` filter
covers the whole model. Tie the captured model to the saved VRM's SHA-256.
An incomplete mesh inventory or a preview of a different output can invalidate
an otherwise successful collision report.

Evaluate ribbon self-intersection, interference during body motion and visual
appearance separately. Zero intersections under the ordinary-pose test does
not prove a pleasing silhouette, a closed gap from every angle or safety under
strong head bending. Preserve the tested pose set and the remaining limits
with the accepted output.

## Preserve local texture and skinning behavior

For local texture repair, follow UV triangle membership. A region selected
only by an approximate image rectangle can affect an unrelated surface mapped
into that region. Keep the intended mesh surface and its UV triangles aligned
when deciding which pixels to repair.

After reducing skin influences to four weights, repeat the motion checks on
the actual exported model. A result on the unreduced weights does not establish
the behavior of the delivered VRM.

## Failed shortcuts and acceptance

Thinning the ribbon, or relying only on a thick back rim to close gaps, did not
resolve the reconstruction as a whole. Compare the changed silhouette and
motion behavior together with the gap itself; fixing one view can worsen
another. The K delivery retains upper and rear-oblique gaps and interference
under strong downward head bending. Acceptance of the ordinary-pose result
must retain those limits rather than turn them into an unrestricted claim.
