"""流光转速测量 v2。

彗头判据：色谱最头端是粉红/品红（#ff4d94 → #e14dff），特征是 R 高、G 低、B 中高。
（不用「R-G 最大」—— sRGB 转换会把高饱和像素裁剪成 (255,0,255)/(255,0,0) 极端值，
 尾部的黄段也会冒出 R-G=255 的假头。）

头部前端 = 粉红像素中「顺时针方向最领先」的一小簇；
速度用帧间欧氏位移 ÷ 真实时间戳得到，不依赖环参数化（跨圆角时弦长略短，取中位数）。

用法: python glow_speed2.py <frames_dir> [tag]
"""
import glob, math, os, sys
from PIL import Image


def pink_head(path, band=44, step=1):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    px = im.load()
    cx0, cy0 = W / 2, H / 2
    pts = []
    for y in range(0, H, step):
        in_band_y = y < band or y >= H - band
        for x in range(0, W, step):
            if not (in_band_y or x < band or x >= W - band):
                continue
            r, g, b = px[x, y]
            # 粉红/品红：R 高、G 低、B 不低（排除黄/绿/青/蓝）
            if r > 205 and g < 130 and b > 95:
                pts.append((x, y))
    if not pts:
        return None
    # 顺时针运动 → 数学极角 θ 递减；取 θ 最小的一簇作为头部前端
    def theta(p):
        return math.atan2(-(p[1] - cy0), p[0] - cx0)
    pts.sort(key=theta)
    k = max(1, len(pts) // 20)
    lead = pts[:k]
    hx = sum(p[0] for p in lead) / k
    hy = sum(p[1] for p in lead) / k
    return hx, hy, len(pts), W, H


def run(d, tag="expand"):
    stamps = {}
    f = os.path.join(d, "timestamps.tsv")
    if os.path.exists(f):
        for line in open(f):
            p = line.split()
            if len(p) == 3 and p[0] == tag:
                stamps[int(p[1])] = float(p[2])
    files = sorted(glob.glob(f"{d}/{tag}_f*.png"))
    obs = []
    for i, fp in enumerate(files):
        h = pink_head(fp)
        if h is None:
            print(f"  f{i:02d} 未检出粉红头部")
            continue
        hx, hy, n, W, H = h
        obs.append((stamps.get(i, i * 0.4), hx, hy, n))
        print(f"  f{i:02d} t={obs[-1][0]:6.3f}s 头部前端=({hx:7.1f},{hy:7.1f}) 粉红像素={n}")
    if len(obs) < 4:
        return None
    dists, dts = [], []
    for k in range(1, len(obs)):
        d = math.hypot(obs[k][1] - obs[k - 1][1], obs[k][2] - obs[k - 1][2])
        dt = obs[k][0] - obs[k - 1][0]
        dists.append(d); dts.append(dt)
    dists_s = sorted(dists); dts_s = sorted(dts)
    med_d = dists_s[len(dists_s) // 2]
    med_dt = dts_s[len(dts_s) // 2]
    mean_v = sum(dists) / sum(dts)
    return dict(med_v=med_d / med_dt, mean_v=mean_v, med_d=med_d, med_dt=med_dt,
                span=obs[-1][0] - obs[0][0], n=len(obs))


res = {}
for d in sys.argv[1:]:
    print(f"=== {d} ===")
    r = run(d)
    if r:
        print(f"--> 中位速度 {r['med_v']:.1f} px/s | 平均速度 {r['mean_v']:.1f} px/s | "
              f"跨时 {r['span']:.2f}s | 帧数 {r['n']}")
        res[d] = r
if len(res) == 2:
    ks = list(res)
    print("\n=== 两版对比 ===")
    print(f"{ks[0]}: {res[ks[0]]['med_v']:.1f} px/s")
    print(f"{ks[1]}: {res[ks[1]]['med_v']:.1f} px/s")
    print(f"速度比 = {res[ks[1]]['med_v'] / res[ks[0]]['med_v']:.4f}")
