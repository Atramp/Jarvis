"""流光帧测量：四边带彩色覆盖比例（= 彗星占周长比例的直接代理）+ 连续性（串珠/断档检测）。

用法: python tools/glow-verify/glow_measure.py <frames_dir> [band_lo band_hi sat_thr]
"""
import glob, sys
from PIL import Image


def is_colored(px, thr):
    r, g, b, a = px
    if a < 40:
        return False
    return (max(r, g, b) - min(r, g, b)) > thr


def measure(path, d0=2, d1=22, thr=30):
    im = Image.open(path).convert("RGBA")
    W, H = im.size
    px = im.load()
    if H < 2 * d1 + 4:
        d1 = max(d0 + 2, H // 2 - 2)

    strips = {}
    strips["top"] = [(x, y) for x in range(W) for y in range(d0, min(d1, H))]
    strips["bottom"] = [(x, y) for x in range(W) for y in range(max(0, H - d1), max(0, H - d0))]
    strips["left"] = [(x, y) for x in range(d0, min(d1, W)) for y in range(min(d1, H // 2), max(min(d1, H // 2), H - d1))]
    strips["right"] = [(x, y) for x in range(max(0, W - d1), max(0, W - d0)) for y in range(min(d1, H // 2), max(min(d1, H // 2), H - d1))]

    total = 0
    colored = 0
    per_edge = {}
    for name, pts in strips.items():
        c = 0
        # 连续段统计（按坐标顺序）
        flags = [is_colored(px[x, y], thr) for (x, y) in pts]
        runs, cur = [], 0
        for f in flags:
            if f:
                cur += 1
            elif cur:
                runs.append(cur); cur = 0
        if cur:
            runs.append(cur)
        c = sum(runs)
        total += len(pts)
        colored += c
        per_edge[name] = (c, len(pts), len(runs), max(runs) if runs else 0)
    return dict(size=(W, H), ratio=colored / max(1, total), per_edge=per_edge)


def main():
    d = sys.argv[1]
    d0 = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    d1 = int(sys.argv[3]) if len(sys.argv) > 3 else 22
    thr = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    print(f"# dir={d} band=[{d0},{d1}) sat>{thr}")
    for tag in ("expand", "collapse"):
        files = sorted(glob.glob(f"{d}/{tag}_f*.png"))
        if not files:
            continue
        print(f"=== {tag} ===")
        ratios = []
        for f in files:
            r = measure(f, d0, d1, thr)
            ratios.append(r["ratio"])
            frag = " ".join(f"{k}={v[2]}段/最长{v[3]}" for k, v in r["per_edge"].items())
            print(f"{f.split('/')[-1]} {r['size']} 覆盖={r['ratio']:.3f} | {frag}")
        print(f"--- {tag}: 平均 {sum(ratios)/len(ratios):.3f} 峰值 {max(ratios):.3f} 谷值 {min(ratios):.3f}")


main()
