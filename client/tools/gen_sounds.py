#!/usr/bin/env python3
"""合成小智 IM 的提示音（无需外部素材，纯数学合成 WAV）。

生成五个文件到 assets/sounds/：
  message.wav   收到新消息：短促双音「叮咚」
  ringtone.wav  来电铃声：双音振铃（循环播放）
  outgoing.wav  呼出回铃：450Hz 单音「嘟——嘟——」（循环播放）
  scan_ok.wav   扫码成功：极短促高音「嘀」（一次成功录一笔）
  scan_fail.wav 扫码失败：两声低音「嗡-嗡」（没记上时也要听得出来）

参数：22050Hz / 16bit / 单声道，带淡入淡出防爆音。
"""
import math
import os
import struct
import wave

SR = 22050  # 采样率，够用且体积只有 44.1k 的一半


def tone(freq, dur, amp=0.5, attack=0.005, release=0.03, decay=8.0):
    """生成一个带包络的正弦音（attack 淡入 + 指数衰减 + release 淡出）"""
    n = int(SR * dur)
    out = []
    for i in range(n):
        t = i / SR
        # 指数衰减让音色更像「叮」而不是「哔」
        env = math.exp(-decay * t)
        if i < SR * attack:
            env *= i / (SR * attack)
        tail = n - i
        if tail < SR * release:
            env *= tail / (SR * release)
        out.append(amp * env * math.sin(2 * math.pi * freq * t))
    return out


def mix(*tracks):
    """多音轨相加后限幅"""
    n = max(len(t) for t in tracks)
    buf = [0.0] * n
    for t in tracks:
        for i, v in enumerate(t):
            buf[i] += v
    peak = max(abs(v) for v in buf) or 1.0
    if peak > 1.0:  # 归一化，避免叠加削波
        buf = [v / peak for v in buf]
    return buf


def silence(dur):
    return [0.0] * int(SR * dur)


def write(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # 末尾再补 8ms 静音，防止 release 被截断产生「咔哒」声
    samples = samples + silence(0.008)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b''.join(
            struct.pack('<h', int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        w.writeframes(frames)
    print('%-14s %6.2fs  %6.1f KB' % (os.path.basename(path), len(samples) / SR,
                                      os.path.getsize(path) / 1024))


# 1) 消息提示音：短促双音（880Hz -> 1174.7Hz，D6 大三度上行，明亮不刺耳）
msg = tone(880.0, 0.085, amp=0.55, decay=10) + tone(1174.7, 0.12, amp=0.55, decay=9)

# 2) 来电铃声：440+480Hz 双音模拟话机振铃，响 1.0s 停 0.3s，两组
ring = []
for _ in range(2):
    ring += mix(tone(440.0, 1.0, amp=0.42, decay=1.2, release=0.05),
                tone(480.0, 1.0, amp=0.42, decay=1.2, release=0.05))
    ring += silence(0.3)

# 3) 呼出回铃：450Hz（国内回铃音标准），响 0.45s 停 0.75s；节奏比真实的 1s/4s 快，
#    否则主叫会误以为没拨出去
out = []
for _ in range(2):
    out += tone(450.0, 0.45, amp=0.4, decay=1.5, release=0.05) + silence(0.75)

# 4) 扫码成功「嘀」：2093Hz（C7）极短促 70ms。
#    ⚠️ 取**高音 + 极短**不是随手定的：
#      · 门店现场很吵（冷柜压缩机、人声），低音会被直接盖掉；
#      · 连扫一整排货架时，声音长了会互相糊成一片，听不出扫了几件。
#    这就是超市扫码枪那个"嘀"的手感，员工听到这个音才知道这一件记上了。
ok_beep = tone(2093.0, 0.07, amp=0.62, decay=5, release=0.015)

# 5) 扫码失败「嗡-嗡」：两声 196Hz 低音，中间隔 70ms。
#    和成功音的**音色差距要足够大**（高/短 vs 低/双）——
#    现场是"听见了就继续扫下一件"，没人会盯着屏幕确认，
#    两个音听着差不多的话，失败会被当成成功，错误数据就混进去了。
fail_buzz = tone(196.0, 0.11, amp=0.5, decay=5, release=0.02)
fail_beep = fail_buzz + silence(0.07) + tone(196.0, 0.13, amp=0.5, decay=5, release=0.02)

base = os.path.join(os.path.dirname(__file__), '..', 'assets', 'sounds')
base = os.path.abspath(base)
write(os.path.join(base, 'message.wav'), msg)
write(os.path.join(base, 'ringtone.wav'), ring)
write(os.path.join(base, 'outgoing.wav'), out)
write(os.path.join(base, 'scan_ok.wav'), ok_beep)
write(os.path.join(base, 'scan_fail.wav'), fail_beep)
print('输出目录:', base)
