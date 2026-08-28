"""Draw the three figures the article uses, into output/figures/.

The numbers are not recomputed here. The breakdown and resampling figures carry
the values this lab's README already publishes, so a figure can never disagree
with the record it illustrates; the saturation figure is the only one drawn from
data, and it reads the raw trace of a `mise run saturation` run.

Rendering goes through headless Chrome because the figures are hand-written SVG:
that keeps real font rendering and exact geometry without adding a plotting
dependency to the lab.
"""

import json
import shutil
import subprocess
from pathlib import Path

LAB = Path(__file__).parent / "output"
OUT = LAB / "figures"

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
CRIT = "#d03b3b"
BLUE, ORANGE = "#2a78d6", "#eb6834"

FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'

# ordinal blue ramp, light -> dark along the pipeline
STAGES = [
    ("preprocess", "#86b6ef", INK),
    ("vision tower", "#5598e7", INK),
    ("streaming gate", "#2a78d6", "#ffffff"),
    ("generation", "#184f95", "#ffffff"),
]

# M4 Max, 4 s segments, median of 3 runs, port commit 2d7ce22, glass_fall, 16-token cap.
# Source: labs 2026/08/27/mage-vl-realtime-benchmark README "現在の結果".
ROWS = [
    ("frames", [0.084, 0.774, 0.013, 3.357]),
    ("codec (8 fps)", [0.498, 0.128, 0.043, 0.828]),
]


def page(title, svg, w, h):
    return (
        f'<!doctype html><meta charset="utf-8"><title>{title}</title>'
        f'<style>html,body{{margin:0;padding:0;background:{SURFACE};}}'
        f'svg{{display:block;font-family:{FONT};}}</style>{svg}'
    )


def right_rounded(x, y, w, h, r=4):
    """Bar segment: square at the baseline, 4px rounded at the data end."""
    r = min(r, w)
    return (
        f'M{x},{y} H{x+w-r} A{r},{r} 0 0 1 {x+w},{y+r} V{y+h-r} '
        f'A{r},{r} 0 0 1 {x+w-r},{y+h} H{x} Z'
    )


def fig_breakdown():
    W, H = 960, 366
    L, R = 156, 852
    plot_w = R - L
    xmax = 4.4
    sx = plot_w / xmax
    bar_h = 24
    y_rows = [176, 240]
    y_top, y_bot = 148, 288
    gap = 2

    s = [f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" '
         f'role="img" aria-label="Stage breakdown of one 4-second segment on M4 Max">']
    s.append(f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>')
    s.append(f'<text x="{L}" y="42" font-size="21" font-weight="600" fill="{INK}">'
             'Where one 4-second segment spends its time</text>')
    s.append(f'<text x="{L}" y="68" font-size="14" fill="{INK2}">'
             'Mac Studio M4 Max &#183; median of 3 runs &#183; 16-token cap &#183; subclip extraction excluded</text>')

    # legend
    lx = L
    for name, fill, _ in STAGES:
        s.append(f'<rect x="{lx}" y="90" width="12" height="12" rx="2" fill="{fill}"/>')
        s.append(f'<text x="{lx+18}" y="100" font-size="13" fill="{INK2}">{name}</text>')
        lx += 18 + len(name) * 7.1 + 26

    # gridlines + ticks
    for t in range(0, 5):
        x = L + t * sx
        s.append(f'<line x1="{x:.1f}" y1="{y_top}" x2="{x:.1f}" y2="{y_bot}" stroke="{GRID}" stroke-width="1"/>')
        s.append(f'<text x="{x:.1f}" y="{y_bot+22}" font-size="12.5" fill="{MUTED}" text-anchor="middle" '
                 f'style="font-variant-numeric:tabular-nums">{t} s</text>')

    # segment-boundary marker at 4 s
    x4 = L + 4.0 * sx
    s.append(f'<line x1="{x4:.1f}" y1="{y_top-14}" x2="{x4:.1f}" y2="{y_bot}" stroke="{CRIT}" stroke-width="1"/>')
    s.append(f'<text x="{x4-8:.1f}" y="{y_top-20}" font-size="12.5" fill="{CRIT}" text-anchor="end">'
             '4 s = one segment. A bar reaching past this line cannot keep up.</text>')

    s.append(f'<line x1="{L}" y1="{y_bot}" x2="{R}" y2="{y_bot}" stroke="{AXIS}" stroke-width="1"/>')

    for (label, vals), y in zip(ROWS, y_rows):
        s.append(f'<text x="{L-16}" y="{y+17}" font-size="14.5" font-weight="600" fill="{INK}" '
                 f'text-anchor="end">{label}</text>')
        x = L
        for i, (v, (name, fill, tcol)) in enumerate(zip(vals, STAGES)):
            w = v * sx
            last = i == len(vals) - 1
            seg_w = w if last else max(w - gap, 0.6)
            if last:
                s.append(f'<path d="{right_rounded(x, y, seg_w, bar_h)}" fill="{fill}"/>')
            else:
                s.append(f'<rect x="{x:.2f}" y="{y}" width="{seg_w:.2f}" height="{bar_h}" fill="{fill}"/>')
            if seg_w >= 58:
                s.append(f'<text x="{x+seg_w/2:.2f}" y="{y+17}" font-size="13" fill="{tcol}" '
                         f'text-anchor="middle" style="font-variant-numeric:tabular-nums">{v:.3f}</text>')
            x += w
        total = sum(vals)
        s.append(f'<text x="{x+12:.2f}" y="{y+17}" font-size="14.5" font-weight="600" fill="{INK}" '
                 f'style="font-variant-numeric:tabular-nums">{total:.3f} s</text>')

    s.append(f'<text x="{L}" y="{H-20}" font-size="12" fill="{MUTED}">'
             'Source: labs 2026/08/27/mage-vl-realtime-benchmark &#183; port commit 2d7ce22 &#183; '
             'glass_fall 768&#215;512 &#183; bfloat16 model + float32 gate</text>')
    s.append('</svg>')
    return page("Latency breakdown", "".join(s), W, H)


def fig_resample():
    W, H = 960, 396
    panels = [
        ("Real-time factor", "lower is better; 1.0 = only just keeping up", 1.75,
         [("M4 Max", 0.862, 0.400), ("M1 Max", 1.542, 0.644)], "{:.3f}", 1.0),
        ("First text after the segment ends", "seconds", 7.9,
         [("M4 Max", 3.180, 1.366), ("M1 Max", 7.166, 2.205)], "{:.3f} s", None),
    ]
    s = [f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" '
         f'role="img" aria-label="Effect of resampling a segment to 8 fps before codec preprocessing">']
    s.append(f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>')
    s.append(f'<text x="40" y="42" font-size="21" font-weight="600" fill="{INK}">'
             'Resampling the segment to 8 fps before codec preprocessing</text>')
    s.append(f'<text x="40" y="68" font-size="14" fill="{INK2}">'
             '4-second segments &#183; median of 3 runs &#183; same video and same commit on both machines</text>')

    lx = 40
    for name, fill in (("codec, source rate (24 fps)", BLUE), ("codec, resampled to 8 fps", ORANGE)):
        s.append(f'<rect x="{lx}" y="90" width="12" height="12" rx="2" fill="{fill}"/>')
        s.append(f'<text x="{lx+18}" y="100" font-size="13" fill="{INK2}">{name}</text>')
        lx += 18 + len(name) * 7.0 + 30

    for p, (ptitle, psub, xmax, rows, fmt, thr) in enumerate(panels):
        ox = 40 + p * 470
        L = ox + 78
        R = ox + 396
        sx = (R - L) / xmax
        y_top, y_bot = 176, 316
        s.append(f'<text x="{ox}" y="146" font-size="15" font-weight="600" fill="{INK}">{ptitle}</text>')
        s.append(f'<text x="{ox}" y="165" font-size="12.5" fill="{MUTED}">{psub}</text>')

        step = 0.5 if xmax < 3 else 2.0
        t = 0.0
        while t <= xmax + 1e-9:
            x = L + t * sx
            s.append(f'<line x1="{x:.1f}" y1="{y_top}" x2="{x:.1f}" y2="{y_bot}" stroke="{GRID}" stroke-width="1"/>')
            lab = f'{t:.1f}' if step < 1 else f'{t:.0f}'
            s.append(f'<text x="{x:.1f}" y="{y_bot+22}" font-size="12.5" fill="{MUTED}" text-anchor="middle" '
                     f'style="font-variant-numeric:tabular-nums">{lab}</text>')
            t += step

        if thr is not None:
            xt = L + thr * sx
            s.append(f'<line x1="{xt:.1f}" y1="{y_top-14}" x2="{xt:.1f}" y2="{y_bot}" stroke="{CRIT}" stroke-width="1"/>')
            s.append(f'<text x="{xt+6:.1f}" y="{y_top-20}" font-size="12.5" fill="{CRIT}">'
                     'falls behind &#8594;</text>')

        s.append(f'<line x1="{L}" y1="{y_bot}" x2="{R}" y2="{y_bot}" stroke="{AXIS}" stroke-width="1"/>')

        y = y_top + 16
        for machine, before, after in rows:
            s.append(f'<text x="{L-14}" y="{y+31}" font-size="14" font-weight="600" fill="{INK}" '
                     f'text-anchor="end">{machine}</text>')
            for v, fill in ((before, BLUE), (after, ORANGE)):
                w = max(v * sx, 5)
                s.append(f'<path d="{right_rounded(L, y, w, 22)}" fill="{fill}"/>')
                s.append(f'<text x="{L+w+10:.1f}" y="{y+16}" font-size="13" fill="{INK}" '
                         f'style="font-variant-numeric:tabular-nums">{fmt.format(v)}</text>')
                y += 24
            y += 20

    s.append(f'<text x="40" y="{H-20}" font-size="12" fill="{MUTED}">'
             'Source: labs 2026/08/27/mage-vl-realtime-benchmark &#183; port commit 2d7ce22 &#183; '
             'glass_fall 768&#215;512 &#183; 16-token cap &#183; bfloat16 model + float32 gate</text>')
    s.append('</svg>')
    return page("Resampling effect", "".join(s), W, H)




RUNS = [
    ("Mac Studio M4 Max", BLUE, LAB / "camera-saturation/m4max-run1.jsonl"),
    ("MacBook Pro M1 Max", ORANGE, LAB / "MacBook-Pro-M1-Max-saturation.jsonl"),
]


def load(path):
    pts = []
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r.get("type") != "result":
            continue
        t = r.get("client_elapsed_s")
        if t is None:
            t = r.get("_client_elapsed_s")
        pts.append((t, r["lag_s"], r.get("dropped", 0)))
    return pts


def panel(ox, oy, title, sub, series, ymax, ystep, yfmt, xmax=125.0):
    L, R = ox + 46, ox + 424
    T, B = oy + 46, oy + 188
    sx = (R - L) / xmax
    sy = (B - T) / ymax
    s = [f'<text x="{ox}" y="{oy+8}" font-size="15" font-weight="600" fill="{INK}">{title}</text>',
         f'<text x="{ox}" y="{oy+27}" font-size="12.5" fill="{MUTED}">{sub}</text>']
    y = 0
    while y <= ymax + 1e-9:
        yy = B - y * sy
        s.append(f'<line x1="{L}" y1="{yy:.1f}" x2="{R}" y2="{yy:.1f}" stroke="{GRID}" stroke-width="1"/>')
        s.append(f'<text x="{L-10}" y="{yy+4:.1f}" font-size="12" fill="{MUTED}" text-anchor="end" '
                 f'style="font-variant-numeric:tabular-nums">{yfmt.format(y)}</text>')
        y += ystep
    for t in (0, 30, 60, 90, 120):
        x = L + t * sx
        s.append(f'<text x="{x:.1f}" y="{B+20}" font-size="12" fill="{MUTED}" text-anchor="middle" '
                 f'style="font-variant-numeric:tabular-nums">{t}</text>')
    s.append(f'<line x1="{L}" y1="{B}" x2="{R}" y2="{B}" stroke="{AXIS}" stroke-width="1"/>')
    s.append(f'<text x="{R}" y="{B+38}" font-size="12" fill="{MUTED}" text-anchor="end">'
             'seconds since the stream started</text>')

    for name, color, pts, key in series:
        d = " ".join(("M" if i == 0 else "L") + f"{L + p[0]*sx:.1f},{B - p[key]*sy:.1f}"
                     for i, p in enumerate(pts))
        s.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2" '
                 f'stroke-linejoin="round" stroke-linecap="round"/>')
        ex, ey = L + pts[-1][0] * sx, B - pts[-1][key] * sy
        s.append(f'<circle cx="{ex:.1f}" cy="{ey:.1f}" r="4" fill="{color}" '
                 f'stroke="{SURFACE}" stroke-width="2"/>')
    return "".join(s), (L, T, B, sx, sy)


def fig_saturation():
    W, H = 960, 424
    data = {name: load(p) for name, _, p in RUNS}
    s = [f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" '
         f'role="img" aria-label="Lag plateaus while dropped frames keep accumulating">',
         f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>',
         f'<text x="40" y="42" font-size="21" font-weight="600" fill="{INK}">'
         'When the model falls behind, the lag stops growing &#8212; the losses do not</text>',
         f'<text x="40" y="68" font-size="14" fill="{INK2}">'
         'Camera path, frames backend &#183; 1 s stride &#183; 4 s window &#183; 2 fps requested &#183; '
         '2-token cap &#183; one 120 s run per machine</text>']
    lx = 40
    for name, color, _ in RUNS:
        s.append(f'<rect x="{lx}" y="90" width="12" height="12" rx="2" fill="{color}"/>')
        s.append(f'<text x="{lx+18}" y="100" font-size="13" fill="{INK2}">{name}</text>')
        lx += 18 + len(name) * 7.0 + 30

    series_lag = [(n, c, data[n], 1) for n, c, _ in RUNS]
    series_drop = [(n, c, data[n], 2) for n, c, _ in RUNS]
    a, _ = panel(40, 148, "Lag behind the live edge", "seconds (the UI shows this as STREAM LAG)",
                 series_lag, 15.0, 5.0, "{:.0f}")
    b, _ = panel(510, 148, "Frames thrown away to hold that lag",
                 "cumulative count of camera frames dropped", series_drop, 180.0, 60.0, "{:.0f}")
    s.append(a)
    s.append(b)

    # direct labels beside each line end
    for ox, key, dy in ((40, 1, 0), (510, 2, 0)):
        L, R = ox + 46, ox + 424
        T, B = 148 + 46, 148 + 188
        sx, sy = (R - L) / 125.0, (B - T) / (15.0 if key == 1 else 180.0)
        for name, color, _ in RUNS:
            p = data[name][-1]
            x, y = L + p[0] * sx, B - p[key] * sy
            short = name.split()[-2] + " " + name.split()[-1]
            s.append(f'<text x="{x-10:.1f}" y="{y-10+dy:.1f}" font-size="12.5" font-weight="600" '
                     f'fill="{INK}" text-anchor="end">{short}</text>')

    s.append(f'<text x="40" y="{H-20}" font-size="12" fill="{MUTED}">'
             'Source: labs 2026/08/27/mage-vl-realtime-benchmark &#183; <tspan style="font-family:ui-monospace,monospace">mise run saturation</tspan> '
             '&#183; raw traces of one run per machine</text>')
    s.append('</svg>')
    html = (f'<!doctype html><meta charset="utf-8"><title>Saturation</title>'
            f'<style>html,body{{margin:0;padding:0;background:{SURFACE};}}'
            f'svg{{display:block;font-family:{FONT};}}</style>' + "".join(s))
    return page("Saturation", "".join(s), W, H)




# Chrome renders the hand-written SVG so the output keeps real font rendering.
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

FIGURES = [
    ("mage-vl-mlx-port-latency-breakdown", fig_breakdown, 960, 366),
    ("mage-vl-mlx-port-resampling", fig_resample, 960, 396),
    ("mage-vl-mlx-port-saturation", fig_saturation, 960, 424),
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build, w, h in FIGURES:
        html = OUT / f"{name}.html"
        html.write_text(build())
        png = OUT / f"{name}.png"
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=2", f"--window-size={w},{h}",
             f"--screenshot={png}", f"file://{html}"],
            check=True, capture_output=True,
        )
        if shutil.which("cwebp"):
            subprocess.run(["cwebp", "-quiet", "-lossless", "-q", "100",
                            str(png), "-o", str(OUT / f"{name}.webp")], check=True)
        print("wrote", png.name)


if __name__ == "__main__":
    main()
