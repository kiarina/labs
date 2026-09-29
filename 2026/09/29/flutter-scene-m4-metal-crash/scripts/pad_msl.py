"""Adds unrelated work to a fragment shader's main, to test whether plain size
or a long branch is enough to crash the compiler.

Usage: python3 scripts/pad_msl.py <in.metal> <out.metal> <count> <mode>

  end-sample  <count> texture samples before `return out;`
  end-alu     <count> sin() terms before `return out;`
  if-end      <count> texture samples inside one `if` before `return out;`
  if-start    <count> texture samples inside one `if` at the top of main

The shader must declare `emissive_texture` / `emissive_textureSmplr` and
write `out.frag_color`, as flutter_scene's standard fragments do.
"""
import sys

src, dst, count, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
lines = open(src).read().split("\n")
ret = max(i for i, l in enumerate(lines) if l.strip() == "return out;")


def sample(k, indent):
    return (f"{indent}out.frag_color.x += emissive_texture.sample(emissive_textureSmplr, "
            f"gl_FragCoord.xy * 0.001 + float2({k}.0 * 0.013, 0.0)).x;")


if mode == "end-sample":
    pad = [sample(k, "    ") for k in range(count)]
elif mode == "end-alu":
    pad = [f"    out.frag_color.x += fast::sin(out.frag_color.y * {k + 1}.0 + gl_FragCoord.x);"
           for k in range(count)]
elif mode in ("if-end", "if-start"):
    pad = ["    if (gl_FragCoord.x > 100.0)", "    {"]
    pad += [sample(k, "        ") for k in range(count)]
    pad += ["    }"]
else:
    sys.exit(f"unknown mode {mode}")

if mode == "if-start":
    top = next(i for i, l in enumerate(lines) if l.startswith("fragment ")) + 3
    lines = lines[:top] + ["    out.frag_color = float4(0.0);"] + pad + lines[top:]
else:
    lines = lines[:ret] + pad + lines[ret:]
open(dst, "w").write("\n".join(lines))
