#!/usr/bin/env python3
"""Verify the per-network outgoing bubble blues in design/tokens.json (D4 amended).

Rules (plan Global Constraints, ruling R15), checked for every shade (top, bottom, mac)
of every network, iMessage included (no exemptions):
  1. HSL hue within 195-235 degrees;
  2. CIELAB L* within +/-12 of the iMessage shade's L* (same shade: top vs top, ...);
  3. CIELAB chroma C* >= 40;
  4. WCAG 2.x contrast of white text on the shade >= 2.5:1;
  5. CIEDE2000 Delta E >= 5 against the same shade of every other network.

Usage: python3 -I design/check-palette.py [tokens.json]
Prints a Markdown table; exits 1 if any rule fails. Standard library only.
"""
import json, math, os, sys

HUE_MIN, HUE_MAX, MIN_CONTRAST, MIN_DE = 195.0, 235.0, 2.5, 5.0
MAX_DL, MIN_C = 12.0, 40.0
REF = 'imessage'
SHADES = ('top', 'bottom', 'mac')


def rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def hue(h):
    r, g, b = rgb(h)
    mx, mn = max(r, g, b), min(r, g, b)
    if mx == mn:
        return 0.0
    d = mx - mn
    if mx == r:
        hh = ((g - b) / d) % 6
    elif mx == g:
        hh = (b - r) / d + 2
    else:
        hh = (r - g) / d + 4
    return hh * 60


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(h):
    r, g, b = (lin(c) for c in rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_white(h):
    return 1.05 / (luminance(h) + 0.05)


def lab(h):
    r, g, b = (lin(c) for c in rgb(h))
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.0
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def ciede2000(c1, c2):
    L1, a1, b1 = lab(c1)
    L2, a2, b2 = lab(c2)
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360
    h2p = math.degrees(math.atan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    if C1p * C2p == 0:
        dhp = 0
    else:
        dhp = h2p - h1p
        if dhp > 180: dhp -= 360
        elif dhp < -180: dhp += 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dhp / 2))
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    if C1p * C2p == 0:
        hbp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hbp = (h1p + h2p) / 2
    else:
        hbp = (h1p + h2p + 360) / 2 if h1p + h2p < 360 else (h1p + h2p - 360) / 2
    T = (1 - 0.17 * math.cos(math.radians(hbp - 30)) + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6)) - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    dth = 30 * math.exp(-(((hbp - 275) / 25) ** 2))
    Rc = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2)
    Sc, Sh = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * dth)) * Rc
    return math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))


def lch(h):
    L, a, b = lab(h)
    return L, math.hypot(a, b)


def check(nets):
    rows, fails = [], []
    names = list(nets)
    for n in names:
        for s in SHADES:
            c = nets[n][s]
            hh, cr = hue(c), contrast_white(c)
            L, C = lch(c)
            dL = L - lch(nets[REF][s])[0]
            others = [(ciede2000(c, nets[m][s]), m) for m in names if m != n]
            de, nearest = min(others)
            checks = ((HUE_MIN <= hh <= HUE_MAX, f'hue {hh:.1f}'), (abs(dL) <= MAX_DL, f'dL* {dL:+.1f}'),
                      (C >= MIN_C, f'C* {C:.1f}'), (cr >= MIN_CONTRAST, f'contrast {cr:.2f}'),
                      (de >= MIN_DE, f'dE {de:.1f} vs {nearest}'))
            fails += [f'{n}.{s} {c}: {what}' for ok, what in checks if not ok]
            rows.append((n, s, c.upper(), hh, L, dL, C, cr, de, nearest, all(ok for ok, _ in checks)))
    return rows, fails


def markdown(rows):
    out = [f'| Network | Shade | Hex | Hue ° ({HUE_MIN:.0f}–{HUE_MAX:.0f}) | L* | ΔL* vs iMessage (±{MAX_DL:.0f}) | C* (≥ {MIN_C:.0f}) '
           f'| White contrast (≥ {MIN_CONTRAST}) | Min ΔE2000 (≥ {MIN_DE:.0f}) | Nearest | Pass |',
           '|---|---|---|---|---|---|---|---|---|---|---|']
    for n, s, c, hh, L, dL, C, cr, de, near, ok in rows:
        out.append(f'| {n} | {s} | `{c}` | {hh:.1f} | {L:.1f} | {dL:+.1f} | {C:.1f} | {cr:.2f} | {de:.1f} | {near} | {"yes" if ok else "**NO**"} |')
    return '\n'.join(out)


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    path = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tokens.json')
    nets = json.load(open(path))['color']['outgoingByNetwork']
    rows, fails = check(nets)
    print(markdown(rows))
    print()
    print('ALL PASS' if not fails else 'FAILURES:\n' + '\n'.join('  - ' + f for f in fails))
    sys.exit(1 if fails else 0)
