# -*- coding: utf-8 -*-
"""
公共 TURN 中继可用性探测（只读，不改任何配置）。

背景：家宽没有入站端口映射，自建 coturn 的公网端口进不来；
ZeroNews 免费版又不支持 TCP/UDP 隧道。所以先探一探「免费公共 TURN」
能不能顶一阵子——它零成本、零配置，而且 ICE 是服务端下发的，
接上去客户端不用重装。

用法：
    python tools/turn_probe.py
    python tools/turn_probe.py 61.155.1.1        # 也可顺便测指定 IP 的 UDP 3478

判定：
    STUN 可达      → 服务器活着，网络能到
    ALLOCATE 成功  → 真的能中继（还会打印分配到的 relay 地址）
"""
import binascii
import hashlib
import hmac
import os
import socket
import struct
import sys

MAGIC = 0x2112A442
BIND_REQ, BIND_OK = 0x0001, 0x0101
ALLOC_REQ, ALLOC_OK, ALLOC_ERR = 0x0003, 0x0103, 0x0113

A_XOR_MAPPED = 0x0020
A_XOR_RELAYED = 0x0016
A_REALM = 0x0014
A_NONCE = 0x0015
A_ERROR = 0x0009
A_XOR_PEER = 0x0012

# 免费公共 TURN 候选。Metered 的 openrelay 是社区里最常被引用的一个。
CANDIDATES = [
    # (host, port, transport, username, password, 备注)
    ("openrelay.metered.ca", 80, "udp", "openrelayproject", "openrelayproject", "Metered 免费中继"),
    ("openrelay.metered.ca", 3478, "udp", "openrelayproject", "openrelayproject", "Metered 免费中继"),
    ("openrelay.metered.ca", 443, "udp", "openrelayproject", "openrelayproject", "Metered 免费中继"),
    ("openrelay.metered.ca", 443, "tcp", "openrelayproject", "openrelayproject", "Metered 免费中继(TCP)"),
    ("turn.p2pquake.net", 3478, "udp", "", "", "p2pquake 公共中继(无认证)"),
]


def attr(t, v):
    pad = (4 - len(v) % 4) % 4
    return struct.pack("!HH", t, len(v)) + v + b"\x00" * pad


def build(mtype, attrs, tid):
    body = b"".join(attr(t, v) for t, v in attrs)
    return struct.pack("!HHI", mtype, len(body), MAGIC) + tid + body


def build_auth(mtype, attrs, tid, key):
    body = b"".join(attr(t, v) for t, v in attrs)
    ln = len(body) + 24  # MESSAGE-INTEGRITY 占 24 字节，长度要把它算进去
    header = struct.pack("!HHI", mtype, ln, MAGIC) + tid
    mac = hmac.new(key, header + body, hashlib.sha1).digest()
    body2 = body + attr(0x0008, mac)
    return struct.pack("!HHI", mtype, len(body2), MAGIC) + tid + body2


def parse(data):
    if len(data) < 20:
        return None, []
    mtype, mlen = struct.unpack("!HH", data[:4])
    out, i, end = [], 20, min(20 + mlen, len(data))
    while i + 4 <= end:
        t, l = struct.unpack("!HH", data[i:i + 4])
        out.append((t, data[i + 4:i + 4 + l]))
        i += 4 + l + ((4 - l % 4) % 4)
    return mtype, out


def dec_ip4(raw, tid):
    # XOR-MAPPED / XOR-RELAYED：端口和前 4 字节 IP 都要跟 magic cookie 异或
    port = struct.unpack("!H", raw[2:4])[0] ^ (MAGIC >> 16)
    ip = bytes(b ^ m for b, m in zip(raw[4:8], struct.pack("!I", MAGIC)))
    return "%s:%d" % (socket.inet_ntoa(ip), port)


def get(attrs, t):
    for k, v in attrs:
        if k == t:
            return v
    return None


def err_text(v):
    code = v[2] if len(v) > 2 else 0
    reason = v[4:].decode("utf-8", "replace")
    return "%d %s" % (code, reason)


def stun_bind(sock, host, port):
    """不带认证的 STUN Binding：只验服务器是否活着。"""
    tid = os.urandom(12)
    sock.sendto(build(BIND_REQ, [], tid), (host, port))
    data, _ = sock.recvfrom(2048)
    mtype, attrs = parse(data)
    if mtype != BIND_OK:
        return None, "响应类型 0x%04x（期望 0x0101）" % mtype
    raw = get(attrs, A_XOR_MAPPED)
    if raw is None:
        return None, "无 XOR-MAPPED-ADDRESS"
    return dec_ip4(raw, tid), None


def turn_alloc(host, port, transport, user, pwd, timeout=6):
    """完整走一遍 TURN Allocate：先拿 401 的 realm/nonce，再带认证重发。"""
    fam = socket.AF_INET
    sock = socket.socket(fam, socket.SOCK_STREAM if transport == "tcp" else socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
    except Exception as e:
        sock.close()
        return None, "连接失败 %s" % e

    def send_recv(pkt):
        if transport == "tcp":
            sock.sendall(pkt)
            head = sock.recv(20)
            if len(head) < 20:
                raise IOError("TCP 短读")
            mlen = struct.unpack("!H", head[2:4])[0]
            rest = b""
            while len(rest) < mlen:
                chunk = sock.recv(mlen - len(rest))
                if not chunk:
                    break
                rest += chunk
            return head + rest
        # UDP：socket 已 connect，用 send 即可（Windows 上对已连接 socket 用 sendto 会报错）
        sock.send(pkt)
        return sock.recv(4096)

    proto = 17 if transport == "udp" else 6
    # build()/build_auth() 收的是 (类型, 值) 对，别把 attr() 打包结果再传进去
    rt = (0x0019, struct.pack("!BBBB", proto, 0, 0, 0))

    tid = os.urandom(12)
    try:
        data = send_recv(build(ALLOC_REQ, [rt], tid))
    except Exception as e:
        sock.close()
        return None, "无响应 %s" % e

    mtype, attrs = parse(data)
    if mtype == ALLOC_OK:
        raw = get(attrs, A_XOR_RELAYED)
        sock.close()
        return (dec_ip4(raw, tid) if raw else "allocated"), None
    if mtype != ALLOC_ERR:
        sock.close()
        return None, "响应类型 0x%04x" % mtype

    realm = get(attrs, A_REALM)
    nonce = get(attrs, A_NONCE)
    if not realm or not nonce:
        ev = get(attrs, A_ERROR)
        msg = err_text(ev) if ev else "未知错误"
        sock.close()
        return None, msg + "（且未返回 realm/nonce，可能是不支持匿名）"

    if not user:
        sock.close()
        return None, "需要认证但未提供账号"

    key = hashlib.md5(b"%s:%s:%s" % (user.encode(), realm, pwd.encode())).digest()
    tid2 = os.urandom(12)
    req = build_auth(ALLOC_REQ, [
        rt,
        (0x0006, user.encode()),   # USERNAME
        (A_REALM, realm),
        (A_NONCE, nonce),
    ], tid2, key)
    try:
        data2 = send_recv(req)
    except Exception as e:
        sock.close()
        return None, "认证请求无响应 %s" % e
    sock.close()

    mtype2, attrs2 = parse(data2)
    if mtype2 == ALLOC_OK:
        raw = get(attrs2, A_XOR_RELAYED)
        return (dec_ip4(raw, tid2) if raw else "allocated"), None
    ev = get(attrs2, A_ERROR)
    return None, err_text(ev) if ev else "响应类型 0x%04x" % mtype2


def udp_reach(host, port, timeout=4):
    """最简单的 UDP 可达性：发个 STUN Binding，看有没有回。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        return stun_bind(sock, host, port)
    except Exception as e:
        return None, "超时/无响应（%s）" % e
    finally:
        sock.close()


def main():
    print("=" * 66)
    print("公共 TURN 中继探测")
    print("=" * 66)

    if len(sys.argv) > 1:
        extra = sys.argv[1]
        print("\n[额外] 自建 coturn UDP 3478 @ %s" % extra)
        res, err = udp_reach(extra, 3478)
        print("   %s" % ("OK  中继活着，映射地址 %s" % res if res else "FAIL " + err))

    ok_list = []
    for host, port, tr, user, pwd, note in CANDIDATES:
        label = "%s:%d/%s" % (host, port, tr)
        try:
            res, err = turn_alloc(host, port, tr, user, pwd)
        except Exception as e:
            res, err = None, "异常 %s" % e
        if res:
            print("\n[OK]   %-38s %s" % (label, note))
            print("       relay 地址: %s" % res)
            ok_list.append((host, port, tr, user, pwd))
        else:
            print("\n[FAIL] %-38s %s" % (label, err))

    print("\n" + "=" * 66)
    if ok_list:
        print("可用中继 %d 个：" % len(ok_list))
        for h, p, tr, u, pw in ok_list:
            print("   turn:%s:%d?transport=%s" % (h, p, tr))
        print("\n可直接写进飞牛 docker/.env 的 TURN_URLS（逗号分隔多条）：")
        print("   TURN_URLS=" + ",".join(
            "turn:%s:%d?transport=%s" % (h, p, tr) for h, p, tr, _, _ in ok_list))
        print("   TURN_USERNAME=%s" % ok_list[0][3])
        print("   TURN_CREDENTIAL=%s" % ok_list[0][4])
    else:
        print("没有任何候选可用 —— 走自建 coturn + 端口映射/付费隧道。")
    print("=" * 66)


if __name__ == "__main__":
    main()
