#!/usr/bin/env python3
# 首批美术资产程序化生成（docs/tech/05-美术管线.md §7，14 清单 #7：零外部版权，纯标准库合成，可复跑）。
# 用法：python3 game/tools/gen_art.py  →  写入 game/assets/art/{units,portraits}/*.png（128px RGBA 透明底）
# 风格：剪影 + 墨色渐变 + 金墨描边（与主屏绘卷一致，04 §4 ink/金墨配色）；头像叠识别色描边。
# 管线：512px 超采样栅格化（多边形扫描线 + 圆）→ 盒滤波降采样 128px = 抗锯齿（filter on 平滑档，tech/05 §4）。
import os
import struct
import zlib

SS = 512          # 超采样边长（4x）
OUT_SIZE = 128    # 交付档（tech/05 §3：单位 128 / 头像 128）
HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.normpath(os.path.join(HERE, "..", "assets", "art"))

INK_TOP = (26, 26, 44)      # 墨色渐变顶（微亮的深蓝黑）
INK_BOTTOM = (4, 4, 12)     # 墨色渐变底
GOLD = (224, 181, 82)       # 金墨描边（04 §4 GOLD）
PAPER = (216, 209, 184)     # 空白页/纸面
TEAL = (92, 184, 172)       # 珂兰识别色（青）
RUST = (216, 132, 62)       # 老费识别色（橙褐）

# 固定种子 LCG（确定性噪声：可复跑逐字节一致，同 gen_audio.py 口径）
_state = [20261109]


def rnd():
    _state[0] = (_state[0] * 1103515245 + 12345) & 0x7FFFFFFF
    return _state[0] / 0x7FFFFFFF


class Canvas:
    """超采样栅格：mask=剪影覆盖，px=RGB 颜色层，al=alpha 层。"""

    def __init__(self):
        self.mask = bytearray(SS * SS)
        self.px = bytearray(SS * SS * 3)
        self.al = bytearray(SS * SS)

    # ---- 形状 primitives（写入 mask；归一化坐标，y 向下）----

    def _set(self, x, y):
        if 0 <= x < SS and 0 <= y < SS:
            self.mask[y * SS + x] = 1

    def circle(self, cx, cy, r):
        x0, x1 = int((cx - r) * SS), int((cx + r) * SS) + 1
        y0, y1 = int((cy - r) * SS), int((cy + r) * SS) + 1
        rr = r * SS
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                dx, dy = x + 0.5 - cx * SS, y + 0.5 - cy * SS
                if dx * dx + dy * dy <= rr * rr:
                    self._set(x, y)

    def ellipse(self, cx, cy, rx, ry):
        x0, x1 = int((cx - rx) * SS), int((cx + rx) * SS) + 1
        y0, y1 = int((cy - ry) * SS), int((cy + ry) * SS) + 1
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                dx = (x + 0.5 - cx * SS) / (rx * SS)
                dy = (y + 0.5 - cy * SS) / (ry * SS)
                if dx * dx + dy * dy <= 1.0:
                    self._set(x, y)

    def poly(self, pts):
        """多边形扫描线填充（even-odd）。pts = [(x,y), ...] 归一化。"""
        p = [(x * SS, y * SS) for x, y in pts]
        ys = [q[1] for q in p]
        y0, y1 = max(0, int(min(ys))), min(SS - 1, int(max(ys)) + 1)
        n = len(p)
        for y in range(y0, y1 + 1):
            yc = y + 0.5
            xs = []
            for i in range(n):
                ax, ay = p[i]
                bx, by = p[(i + 1) % n]
                if (ay <= yc < by) or (by <= yc < ay):
                    xs.append(ax + (yc - ay) * (bx - ax) / (by - ay))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                for x in range(max(0, int(xs[k])), min(SS, int(xs[k + 1]) + 1)):
                    self._set(x, y)

    def ring(self, cx, cy, r, w):
        """圆环（mask 写入；描边环用于光环等）。"""
        x0, x1 = int((cx - r - w) * SS), int((cx + r + w) * SS) + 1
        y0, y1 = int((cy - r - w) * SS), int((cy + r + w) * SS) + 1
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                d = ((x + 0.5 - cx * SS) ** 2 + (y + 0.5 - cy * SS) ** 2) ** 0.5 / SS
                if r - w <= d <= r + w:
                    self._set(x, y)

    # ---- 着色 ----

    def ink_fill(self):
        """mask 内填墨色纵向渐变 + 固定种子噪声（墨渍颗粒感）。"""
        for y in range(SS):
            t = y / (SS - 1)
            base = [INK_TOP[i] + (INK_BOTTOM[i] - INK_TOP[i]) * t for i in range(3)]
            for x in range(SS):
                if not self.mask[y * SS + x]:
                    continue
                n = (rnd() - 0.5) * 10.0
                o = (y * SS + x) * 3
                for i in range(3):
                    self.px[o + i] = max(0, min(255, int(base[i] + n)))
                self.al[y * SS + x] = 255

    def rim(self, color, thick=2, top_only=True):
        """剪影边缘描边：朝光面（上/左）着描边色。thick 为超采样像素宽。"""
        edge = []
        for y in range(SS):
            for x in range(SS):
                if not self.mask[y * SS + x]:
                    continue
                for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
                    nx, ny = x + dx, y + dy
                    out = nx < 0 or ny < 0 or nx >= SS or ny >= SS or not self.mask[ny * SS + nx]
                    if out and (not top_only or dy <= 0):
                        edge.append((x, y))
                        break
        thick2 = thick * thick
        for ex, ey in edge:
            for y in range(ey - thick, ey + thick + 1):
                for x in range(ex - thick, ex + thick + 1):
                    if 0 <= x < SS and 0 <= y < SS and (x - ex) ** 2 + (y - ey) ** 2 <= thick2 \
                            and self.mask[y * SS + x]:
                        o = (y * SS + x) * 3
                        for i in range(3):
                            # 与墨色底混合，描边不死板
                            self.px[o + i] = int(self.px[o + i] * 0.35 + color[i] * 0.65)

    def paint_circle(self, cx, cy, r, color, alpha=255):
        """细节点画（眼睛/纸面/道具），直接写颜色层，不参与 mask。"""
        x0, x1 = int((cx - r) * SS), int((cx + r) * SS) + 1
        y0, y1 = int((cy - r) * SS), int((cy + r) * SS) + 1
        rr = r * SS
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if not (0 <= x < SS and 0 <= y < SS):
                    continue
                dx, dy = x + 0.5 - cx * SS, y + 0.5 - cy * SS
                if dx * dx + dy * dy <= rr * rr:
                    o = (y * SS + x) * 3
                    a = alpha / 255.0
                    for i in range(3):
                        self.px[o + i] = int(self.px[o + i] * (1 - a) + color[i] * a)
                    self.al[y * SS + x] = max(self.al[y * SS + x], alpha)

    def paint_rect(self, x, y, w, h, color, alpha=255):
        for yy in range(int(y * SS), int((y + h) * SS)):
            for xx in range(int(x * SS), int((x + w) * SS)):
                if 0 <= xx < SS and 0 <= yy < SS:
                    o = (yy * SS + xx) * 3
                    a = alpha / 255.0
                    for i in range(3):
                        self.px[o + i] = int(self.px[o + i] * (1 - a) + color[i] * a)
                    self.al[yy * SS + xx] = max(self.al[yy * SS + xx], alpha)

    def paint_ring(self, cx, cy, r, w, color, alpha=255):
        x0, x1 = int((cx - r - w) * SS), int((cx + r + w) * SS) + 1
        y0, y1 = int((cy - r - w) * SS), int((cy + r + w) * SS) + 1
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if not (0 <= x < SS and 0 <= y < SS):
                    continue
                d = ((x + 0.5 - cx * SS) ** 2 + (y + 0.5 - cy * SS) ** 2) ** 0.5 / SS
                if r - w <= d <= r + w:
                    o = (y * SS + x) * 3
                    a = alpha / 255.0
                    for i in range(3):
                        self.px[o + i] = int(self.px[o + i] * (1 - a) + color[i] * a)
                    self.al[y * SS + x] = max(self.al[y * SS + x], alpha)

    def save(self, path):
        """盒滤波 4x 降采样到 128px 并写 PNG（RGBA8）。"""
        f = SS // OUT_SIZE
        out = bytearray()
        for y in range(OUT_SIZE):
            out.append(0)  # filter type 0
            for x in range(OUT_SIZE):
                r = g = b = a = 0
                for yy in range(y * f, y * f + f):
                    for xx in range(x * f, x * f + f):
                        o = (yy * SS + xx) * 3
                        r += self.px[o]
                        g += self.px[o + 1]
                        b += self.px[o + 2]
                        a += self.al[yy * SS + xx]
                n = f * f
                out += bytes((r // n, g // n, b // n, a // n))
        write_png(path, OUT_SIZE, OUT_SIZE, bytes(out))


def write_png(path, w, h, raw_rgba_scanlines):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw_rgba_scanlines, 9)) + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fp:
        fp.write(png)
    print("生成 %s（%dx%d，%d 字节）" % (path, w, h, len(png)))


# ---------------------------------------------------------------- 首批资产（tech/05 §7）

def unit_ink_imp():
    """墨魈幼体：小团墨滴剪影，双角芽，底部墨须，金墨眼睛。"""
    c = Canvas()
    c.circle(0.5, 0.56, 0.26)                       # 主体墨团
    c.poly([(0.36, 0.40), (0.30, 0.20), (0.46, 0.34)])  # 左角芽
    c.poly([(0.64, 0.40), (0.70, 0.20), (0.54, 0.34)])  # 右角芽
    for i, x in enumerate((0.38, 0.5, 0.62)):       # 底部墨须滴
        c.poly([(x - 0.05, 0.76), (x + 0.05, 0.76), (x, 0.90 - 0.04 * (i % 2))])
    c.ink_fill()
    c.rim(GOLD, thick=2)
    c.paint_circle(0.42, 0.52, 0.030, GOLD)         # 双眼
    c.paint_circle(0.58, 0.52, 0.030, GOLD)
    return c


def unit_ink_fiend():
    """墨魈：魁梧墨团 + 肩部隆起 + 犄角 + 底部滴墨锯齿。"""
    c = Canvas()
    c.ellipse(0.5, 0.55, 0.28, 0.33)                # 躯干
    c.circle(0.28, 0.44, 0.12)                      # 左肩
    c.circle(0.72, 0.44, 0.12)                      # 右肩
    c.poly([(0.32, 0.34), (0.22, 0.10), (0.44, 0.28)])  # 左犄角
    c.poly([(0.68, 0.34), (0.78, 0.10), (0.56, 0.28)])  # 右犄角
    for i in range(5):                              # 底部滴墨锯齿
        x = 0.28 + i * 0.11
        c.poly([(x - 0.05, 0.80), (x + 0.05, 0.80), (x, 0.94 - 0.05 * (i % 2))])
    c.ink_fill()
    c.rim(GOLD, thick=2)
    c.paint_circle(0.41, 0.46, 0.034, GOLD)         # 双目（更大更凶）
    c.paint_circle(0.59, 0.46, 0.034, GOLD)
    return c


def unit_page_warden():
    """守页人：长袍傀儡剪影，头后残页光环，面甲金缝。"""
    c = Canvas()
    c.poly([(0.30, 0.96), (0.40, 0.30), (0.60, 0.30), (0.70, 0.96)])  # 长袍
    c.circle(0.5, 0.235, 0.075)                     # 头
    c.poly([(0.40, 0.32), (0.30, 0.52), (0.38, 0.56)])  # 左垂臂
    c.poly([(0.60, 0.32), (0.70, 0.52), (0.62, 0.56)])  # 右垂臂
    c.ink_fill()
    c.rim(GOLD, thick=2)
    c.paint_ring(0.5, 0.235, 0.135, 0.018, GOLD, 200)   # 残页光环
    c.paint_rect(0.44, 0.225, 0.12, 0.014, GOLD)    # 面甲金缝
    return c


def portrait_player_blank():
    """白页者：兜帽剪影 + 空白页脸，识别色金。"""
    c = Canvas()
    c.poly([(0.28, 0.92), (0.34, 0.30), (0.5, 0.14), (0.66, 0.30), (0.72, 0.92)])  # 兜帽袍
    c.circle(0.5, 0.34, 0.13)                       # 头部（兜帽内）
    c.ink_fill()
    c.rim(GOLD, thick=2)
    c.paint_rect(0.425, 0.27, 0.15, 0.19, PAPER)    # 空白页脸
    c.paint_ring(0.5, 0.34, 0.145, 0.012, GOLD, 160)
    return c


def portrait_companion_kelan():
    """珂兰：清瘦剪影 + 抄本挎包，识别色青。"""
    c = Canvas()
    c.poly([(0.35, 0.92), (0.41, 0.28), (0.5, 0.19), (0.59, 0.28), (0.65, 0.92)])  # 清瘦袍身
    c.circle(0.5, 0.155, 0.075)                     # 头
    c.ink_fill()
    c.rim(TEAL, thick=2)
    c.paint_circle(0.5, 0.16, 0.045, PAPER)         # 面部纸色
    c.paint_rect(0.585, 0.52, 0.11, 0.13, TEAL, 230)  # 抄本挎包（识别色块）
    c.paint_rect(0.60, 0.535, 0.08, 0.02, PAPER)    # 挎包书脊线
    return c


def portrait_companion_laofei():
    """老费：敦实剪影 + 铁钩手，识别色橙褐。"""
    c = Canvas()
    c.ellipse(0.5, 0.62, 0.27, 0.30)                # 敦实躯干
    c.circle(0.5, 0.25, 0.105)                      # 头
    c.poly([(0.42, 0.30), (0.5, 0.46), (0.58, 0.30)])   # 胡须楔
    c.ink_fill()
    c.rim(RUST, thick=2)
    c.paint_circle(0.5, 0.23, 0.055, PAPER)         # 面部纸色
    # 铁钩手（识别色粗折线：小圆串近似 J 钩）
    for t in range(12):
        a = -0.5 + t / 11.0 * 1.6
        c.paint_circle(0.74 + 0.055 * __import__("math").cos(a + 2.2),
                       0.52 + 0.07 * __import__("math").sin(a + 2.2) + 0.03 * t / 11.0,
                       0.016, RUST)
    return c


ASSETS = [
    ("units", "unit_ink_imp_128.png", unit_ink_imp),
    ("units", "unit_ink_fiend_128.png", unit_ink_fiend),
    ("units", "unit_page_warden_128.png", unit_page_warden),
    ("portraits", "portrait_player_blank_128.png", portrait_player_blank),
    ("portraits", "portrait_companion_kelan_128.png", portrait_companion_kelan),
    ("portraits", "portrait_companion_laofei_128.png", portrait_companion_laofei),
]


def main():
    for sub, name, fn in ASSETS:
        _state[0] = 20261109  # 每张图独立同种子起点：增删资产互不影响
        fn().save(os.path.join(ART, sub, name))
    print("完成：%d 个资产（tech/05 §7 首批清单）" % len(ASSETS))


if __name__ == "__main__":
    main()
