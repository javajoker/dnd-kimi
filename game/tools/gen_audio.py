#!/usr/bin/env python3
# 首批音频资产程序化生成（docs/framework/14 清单 #6：零外部版权，Python 合成，可复跑）。
# 用法：python3 game/tools/gen_audio.py  →  写入 game/assets/audio/*.wav（44100Hz 16-bit 单声道）
# 循环资产（tide_loop/bgm_camp/bgm_battle）采用频率整数周期量化 + 首尾交叉淡化，循环无接缝。
import math
import os
import random
import struct
import wave

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "audio"))
rng = random.Random(20261109)  # 固定种子：可复跑逐字节一致


def write_wav(name, samples):
    os.makedirs(OUT, exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    gain = 0.89 / peak  # 归一化防削波
    frames = b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, s * gain)) * 32767)) for s in samples)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    print("生成 %s（%.2fs）" % (path, len(samples) / SR))


def q(freq, dur):
    """频率量化到整数周期 → 循环首尾无相位断点。"""
    return round(freq * dur) / dur


def loop_seam(samples, fade_sec=0.5):
    """尾部交叉淡化到头部：生成时多渲染 fade 段并叠回头部，循环无缝。"""
    f = int(fade_sec * SR)
    n = len(samples) - f
    out = samples[:n]
    for i in range(f):
        t = i / f
        out[i] = out[i] * t + samples[n + i] * (1.0 - t)
    return out


def lowpass(samples, coeff):
    """单极点低通。"""
    y = 0.0
    out = []
    for s in samples:
        y += coeff * (s - y)
        out.append(y)
    return out


# ---------------------------------------------------------------- 环境声

def tide_loop():
    """港口潮声：棕噪声（低频涌）+ 慢 LFO 起伏 + 高频水沫层，9s 循环。"""
    dur = 9.0
    n = int(dur * SR) + int(0.5 * SR)  # 多渲染 0.5s 供首尾交叉
    brown = 0.0
    out = []
    for i in range(n):
        t = i / SR
        white = rng.uniform(-1.0, 1.0)
        brown += 0.02 * (white - brown)  # 漏积分 → 棕噪声（低频涌动感）
        hiss = rng.uniform(-1.0, 1.0)
        # 慢 LFO：9s 整 3 周期（涌浪节奏）+ 2 周期反向（错相位增厚），整数周期保循环
        lfo = 0.55 + 0.30 * math.sin(2 * math.pi * 3 * t / dur) \
            + 0.15 * math.sin(2 * math.pi * 2 * t / dur + 1.3)
        out.append(brown * 2.2 * lfo + hiss * 0.04 * max(0.0, lfo - 0.4))
    out = lowpass(out, 0.35)
    return loop_seam(out)


# ---------------------------------------------------------------- SFX

def dice_roll():
    """骰子滚动：短促颗粒噪声串 ~0.5s（由密到疏，模拟托盘里弹跳）。"""
    dur = 0.5
    n = int(dur * SR)
    out = [0.0] * n
    t = 0.02
    while t < dur - 0.03:
        glen = int(rng.uniform(0.006, 0.014) * SR)
        amp = rng.uniform(0.4, 1.0) * (1.0 - 0.5 * t / dur)
        start = int(t * SR)
        for j in range(glen):
            if start + j >= n:
                break
            env = math.sin(math.pi * j / glen)  # 颗粒包络
            out[start + j] += rng.uniform(-1.0, 1.0) * env * amp
        t += rng.uniform(0.024, 0.042) + 0.02 * t  # 越滚越疏
    return lowpass(out, 0.6)


def dice_land():
    """落定一声：低频顿响 + 起音咔哒。"""
    dur = 0.18
    n = int(dur * SR)
    out = []
    for i in range(n):
        t = i / SR
        thump = math.sin(2 * math.pi * 170 * t) * math.exp(-t * 26.0)
        click = rng.uniform(-1.0, 1.0) * math.exp(-t * 320.0) if t < 0.012 else 0.0
        out.append(thump * 0.9 + click * 0.5)
    return out


def hit():
    """命中钝响：低频衰减正弦 + 短低通噪声。"""
    dur = 0.22
    n = int(dur * SR)
    raw = []
    for i in range(n):
        t = i / SR
        body = math.sin(2 * math.pi * 115 * t) * math.exp(-t * 20.0)
        noise = rng.uniform(-1.0, 1.0) * math.exp(-t * 60.0) if t < 0.05 else 0.0
        raw.append(body + noise * 0.7)
    return lowpass(raw, 0.45)


def crit():
    """暴击亮色：钝响基底（更高基频）+ 金属泛音闪光。"""
    dur = 0.35
    n = int(dur * SR)
    raw = []
    for i in range(n):
        t = i / SR
        body = math.sin(2 * math.pi * 190 * t) * math.exp(-t * 18.0)
        shimmer = (math.sin(2 * math.pi * 880 * t) * 0.5
                   + math.sin(2 * math.pi * 1318.5 * t) * 0.35
                   + math.sin(2 * math.pi * 1760 * t + 0.4) * 0.2) * math.exp(-t * 9.0)
        noise = rng.uniform(-1.0, 1.0) * math.exp(-t * 70.0) if t < 0.04 else 0.0
        raw.append(body * 0.7 + shimmer + noise * 0.5)
    return raw


def heal():
    """治疗：三连上行柔和音（Do-Mi-Sol），慢起音。"""
    dur = 0.6
    n = int(dur * SR)
    notes = [(523.25, 0.0), (659.25, 0.12), (783.99, 0.24)]
    out = []
    for i in range(n):
        t = i / SR
        s = 0.0
        for f, t0 in notes:
            if t >= t0:
                lt = t - t0
                env = min(1.0, lt / 0.03) * math.exp(-lt * 3.5)
                s += math.sin(2 * math.pi * f * lt) * env * 0.6
        out.append(s)
    return out


def page():
    """翻页：扫频低通噪声（纸面摩擦），快起慢收。"""
    dur = 0.28
    n = int(dur * SR)
    y = 0.0
    out = []
    for i in range(n):
        t = i / SR
        frac = t / dur
        coeff = 0.03 + 0.35 * math.sin(math.pi * min(1.0, frac * 1.15))  # 截止先开后合
        y += coeff * (rng.uniform(-1.0, 1.0) - y)
        env = min(1.0, t / 0.02) * (1.0 - frac ** 3)
        out.append(y * env * 1.6)
    return out


def ui_click():
    """UI 点击：极短软木鱼声（中频正弦瞬态 + 轻噪声起音），克制不抢戏。"""
    dur = 0.09
    n = int(dur * SR)
    out = []
    for i in range(n):
        t = i / SR
        body = math.sin(2 * math.pi * 620 * t) * math.exp(-t * 70.0)
        tick = rng.uniform(-1.0, 1.0) * math.exp(-t * 600.0) if t < 0.006 else 0.0
        out.append(body * 0.8 + tick * 0.3)
    return out


# ---------------------------------------------------------------- BGM

def bgm_camp():
    """营地氛围垫：Am(add9) 正弦叠 + 慢包络，30s 循环。"""
    dur = 30.0
    n = int(dur * SR) + int(0.5 * SR)
    # (基频, 振幅, LFO 周期数(整), LFO 相位, 二次谐波量)
    voices = [
        (110.00, 0.50, 2, 0.0, 0.10),   # A2
        (130.81, 0.34, 3, 1.1, 0.08),   # C3
        (164.81, 0.34, 4, 2.2, 0.08),   # E3
        (246.94, 0.20, 5, 0.6, 0.05),   # B3（add9 亮色）
    ]
    out = []
    for i in range(n):
        t = i / SR
        s = 0.0
        for f, amp, cyc, ph, h2 in voices:
            fq = q(f, dur)
            lfo = 0.7 + 0.3 * math.sin(2 * math.pi * cyc * t / dur + ph)
            s += (math.sin(2 * math.pi * fq * t) + h2 * math.sin(4 * math.pi * fq * t)) * amp * lfo
        out.append(s)
    return loop_seam(out)


def bgm_battle():
    """战斗氛围垫：Dm 低音区 + 颤音压迫 + 2Hz 心跳闸口，30s 循环。"""
    dur = 30.0
    n = int(dur * SR) + int(0.5 * SR)
    voices = [
        (73.42, 0.55, 2, 0.0),   # D2
        (87.31, 0.38, 3, 0.9),   # F2
        (110.00, 0.34, 4, 1.7),  # A2
        (130.81, 0.22, 5, 2.6),  # C3
    ]
    out = []
    for i in range(n):
        t = i / SR
        s = 0.0
        for f, amp, cyc, ph in voices:
            fq = q(f, dur)
            lfo = 0.75 + 0.25 * math.sin(2 * math.pi * cyc * t / dur + ph)
            s += math.sin(2 * math.pi * fq * t) * amp * lfo
        trem = 0.7 + 0.3 * math.sin(2 * math.pi * 8 * t / dur)  # 8 整周期颤音
        pulse = (0.5 + 0.5 * math.sin(2 * math.pi * 2 * t)) ** 4  # 2Hz 心跳（60 整周期）
        s = s * trem + math.sin(2 * math.pi * q(55.0, dur) * t) * pulse * 0.35
        out.append(s)
    return loop_seam(out)


def main():
    write_wav("tide_loop.wav", tide_loop())
    write_wav("dice_roll.wav", dice_roll())
    write_wav("dice_land.wav", dice_land())
    write_wav("hit.wav", hit())
    write_wav("crit.wav", crit())
    write_wav("heal.wav", heal())
    write_wav("page.wav", page())
    write_wav("ui_click.wav", ui_click())
    write_wav("bgm_camp.wav", bgm_camp())
    write_wav("bgm_battle.wav", bgm_battle())


if __name__ == "__main__":
    main()
