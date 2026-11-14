# 草侧面过渡变体贴图生成器（BetterGrassify 草坡融合配套）：
# 满绿 blend 面与普通土面交界处，土面边缘画"草蔓延过来"的垂带。
# 变体：u0 侧带 / u1 侧带 / 双侧。列深阶梯 12/8/6/4/3 + 逐列抖动，
# 颜色取自本贴图顶部草线带（调色板天然一致）。
import random
from PIL import Image

SRC = r'F:/yaohai-epic/assets/textures/grass_side.png'
random.seed(20261114)

base = Image.open(SRC).convert('RGBA')
W, H = base.size
pxb = base.load()


def grass_palette():
    """从顶部草线行 (y=0..2) 收集绿像素作垂带调色板。"""
    pal = []
    for y in range(3):
        for x in range(W):
            r, g, b, a = pxb[x, y]
            if g > r + 10 and g > b + 15:
                pal.append((r, g, b))
    return pal or [(80, 105, 50)]


PAL = grass_palette()


def mix(c1, c2, t):
    return tuple(int(round(c1[i] + (c2[i] - c1[i]) * t)) for i in range(3))


def drip_column(x, depth):
    """在列 x 从草线下方垂草：行 3..3+depth，越深混土越多。"""
    for i in range(depth):
        y = 3 + i
        if y >= H:
            break
        r, g, b, a = pxb[x, y]
        grass = random.choice(PAL)
        t = (i + 1) / (depth + 1) * 0.6      # 0.0(顶) → 0.6(最深，剩四成草)
        r2, g2, b2 = mix(grass, (r, g, b), t)
        pxb[x, y] = (r2, g2, b2, a)


def make_variant(side):  # side: 'u0' | 'u1' | 'u01'
    im = base.copy()
    global pxb
    pxb = im.load()
    depths = [12, 8, 6, 4, 3]
    if 'u0' in side:
        for c, d in enumerate(depths):
            drip_column(c, d + random.randint(-1, 1))
    if 'u1' in side:
        for c, d in enumerate(depths):
            drip_column(W - 1 - c, d + random.randint(-1, 1))
    im.save(r'F:/yaohai-epic/assets/textures/grass_side_%s.png' % side)
    # 验证：逐列首个非绿行深度
    for c in [0, 1, 2, 4]:
        col = [(pxb[c, y][1] > pxb[c, y][0] + 10) for y in range(H)]
        print(' variant', side, 'col', c, 'grass depth', sum(col))


for s in ('u0', 'u1', 'u01'):
    make_variant(s)
print('done')
