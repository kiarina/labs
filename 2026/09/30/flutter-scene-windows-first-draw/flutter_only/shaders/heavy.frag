#version 460 core
// A heavy fragment shader shaped like a soft-shadow (PCSS) lookup, the part
// that makes a lit flutter_scene material slow to compile on Windows: for
// each of four cascades, a 9-tap blocker search and a 17-tap filter, with the
// tap offsets looked up by index inside the loops (written as if-chains,
// which is also what the GLSL ES translation of a constant table becomes).
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform sampler2D uTexture;

out vec4 fragColor;

vec2 blockerTap(int i) {
  if (i == 0) return vec2(-0.7313, 0.6949);
  if (i == 1) return vec2(0.5275, -0.4899);
  if (i == 2) return vec2(-0.0091, -0.1010);
  if (i == 3) return vec2(0.3032, 0.5774);
  if (i == 4) return vec2(-0.8123, -0.9433);
  if (i == 5) return vec2(0.6715, -0.1345);
  if (i == 6) return vec2(0.5246, -0.9958);
  if (i == 7) return vec2(-0.1092, 0.4431);
  if (i == 8) return vec2(-0.5425, 0.8905);
  return vec2(0.0);
}

vec2 filterTap(int i) {
  if (i == 0) return vec2(0.8029, -0.9388);
  if (i == 1) return vec2(-0.9491, 0.0828);
  if (i == 2) return vec2(0.8783, -0.2376);
  if (i == 3) return vec2(-0.5668, -0.1558);
  if (i == 4) return vec2(-0.9419, -0.5566);
  if (i == 5) return vec2(-0.1242, -0.0084);
  if (i == 6) return vec2(-0.5338, -0.5383);
  if (i == 7) return vec2(-0.5624, -0.0808);
  if (i == 8) return vec2(-0.4204, -0.9570);
  if (i == 9) return vec2(0.6752, 0.1129);
  if (i == 10) return vec2(0.2846, -0.6282);
  if (i == 11) return vec2(0.9851, 0.7199);
  if (i == 12) return vec2(-0.7582, -0.3346);
  if (i == 13) return vec2(0.4430, 0.4224);
  if (i == 14) return vec2(0.8729, -0.1558);
  if (i == 15) return vec2(0.6601, 0.3406);
  if (i == 16) return vec2(-0.3933, 0.1752);
  return vec2(0.0);
}

float cascade(vec2 uv, float depth, float radius) {
  float blockers = 0.0;
  float count = 0.0;
  for (int i = 0; i < 9; i++) {
    float d = texture(uTexture, uv + blockerTap(i) * radius).r;
    if (d < depth) {
      blockers += d;
      count += 1.0;
    }
  }
  if (count == 0.0) return 1.0;
  float penumbra = (depth - blockers / count) / max(blockers / count, 1e-3);
  float lit = 0.0;
  for (int j = 0; j < 17; j++) {
    vec2 o = filterTap(j) * radius * (1.0 + penumbra);
    lit += step(depth, texture(uTexture, uv + o).r);
  }
  return lit / 17.0;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float depth = 0.5 + 0.25 * sin(uTime + uv.x * 6.0);
  float shadow = 1.0;
  for (int c = 0; c < 4; c++) {
    shadow = min(shadow, cascade(uv * (1.0 + float(c)), depth, 0.002 * float(c + 1)));
  }
  fragColor = vec4(vec3(shadow), 1.0);
}
