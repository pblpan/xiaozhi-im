# -*- coding: utf-8 -*-
"""STUN 探测：判断本机出口是否公网 IP / NAT 类型。

用途：决定飞牛能否自建 coturn 中继（TURN 需要公网可达 + UDP 入站）。
原理：向公共 STUN 发 Binding Request，比对返回的 mapped address 与本机出口 IP。
  - mapped == 出口 IP  -> 公网 IP 或 Full-Cone NAT（有戏）
  - mapped != 出口 IP  -> 在 NAT 后面（CGNAT/端口受限，自建 TURN 需端口映射）
"""
import os
import socket
import struct
import sys
import urllib.request

STUN_SERVERS = [
    ('stun.qq.com', 3478),
    ('stun.miwifi.com', 3478),
    ('stun.chat.bilibili.com', 3478),
    ('stun.hitv.com', 3478),
]

MAGIC = 0x2112A442


def _attr(buf, tid):
    """解析 STUN 属性，返回 (mapped_ip, mapped_port) 或 None"""
    # 跳过 20 字节头
    i = 20
    mapped = None
    while i + 4 <= len(buf):
        atype, alen = struct.unpack('>HH', buf[i:i + 4])
        val = buf[i + 4:i + 4 + alen]
        if atype in (0x0001, 0x0020):  # MAPPED-ADDRESS / XOR-MAPPED-ADDRESS
            if len(val) >= 8 and val[1] == 0x01:
                port = struct.unpack('>H', val[2:4])[0]
                raw = val[4:8]
                if atype == 0x0020:
                    port ^= (MAGIC >> 16)
                    raw = bytes(a ^ b for a, b in zip(raw, struct.pack('>I', MAGIC)))
                ip = '.'.join(str(b) for b in raw)
                mapped = (ip, port)
        i += 4 + alen
        if alen % 4:
            i += 4 - (alen % 4)
    return mapped


def stun_query(host, port, timeout=4.0):
    tid = os.urandom(12)
    pkt = struct.pack('>HHI12s', 0x0001, 0, MAGIC, tid)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(pkt, (host, port))
        data, _ = s.recvfrom(2048)
        return _attr(data, tid)
    finally:
        s.close()


def public_ip():
    for url in ('https://ipinfo.io/ip', 'https://api.ipify.org', 'https://ifconfig.me/ip'):
        try:
            with urllib.request.urlopen(url, timeout=6) as r:
                return r.read().decode().strip()
        except Exception:
            continue
    return None


def main():
    print('=' * 58)
    print('  STUN / NAT 探测  —— 判断飞牛能否自建 TURN 中继')
    print('=' * 58)

    eip = public_ip()
    print(f'\n[1] 本机出口公网 IP : {eip or "获取失败"}')

    print('\n[2] STUN 映射地址（UDP 3478 出站是否可用）')
    results = []
    for host, port in STUN_SERVERS:
        try:
            m = stun_query(host, port)
            if m:
                tag = '公网/全锥' if eip and m[0] == eip else 'NAT 后'
                print(f'    {host:<26} -> {m[0]}:{m[1]}   [{tag}]')
                results.append(m)
            else:
                print(f'    {host:<26} -> 无映射属性')
        except Exception as e:
            print(f'    {host:<26} -> 失败 ({type(e).__name__}: {e})')

    print('\n[3] 结论')
    if not results:
        print('    ✗ 所有 STUN 均不可达：UDP 3478 出站被拦，')
        print('      跨网 WebRTC 打洞基本无望，必须依赖 TURN 中继。')
    elif eip and results[0][0] == eip:
        print(f'    ✓ 映射地址与出口 IP 一致（{eip}）')
        print('      -> 有公网 IP 或全锥形 NAT，飞牛自建 coturn 有希望。')
        print('      -> 还需确认路由器能做 3478/udp+tcp 与 49152-65535/udp 端口映射。')
    else:
        print(f'    ⚠ 出口 {eip}，STUN 看到的是 {results[0][0]}')
        print('      -> 处于 NAT 之后（可能是运营商大内网）。')
        print('      -> TURN 需要公网 IP + 端口映射，飞牛直连自建走不通。')

    # 多 STUN 一致性 = 判断是否对称 NAT 的粗略依据
    if len(results) >= 2:
        same = len({m[1] for m in results}) == 1
        print(f'\n[4] 多服务器端口一致性 : {"一致（非对称 NAT）" if same else "不一致（疑似对称 NAT，打洞难度高）"}')
    print()


if __name__ == '__main__':
    sys.exit(main())
