# -*- coding: utf-8 -*-
"""通过 UPnP IGD 问路由器要「WAN 口公网 IP」。

背景：要判断飞牛能不能自建 TURN 中继，核心就一个问题 ——
路由器 WAN 口拿到的是**真公网 IP**，还是运营商大内网地址（100.64/10 等）。
两者从内网看出口 IP 是一模一样的，只有问路由器才知道。

顺带还能申请端口映射（--map），成功后用户完全不用手动配路由器。

用法：
    python upnp_probe.py                  # 只探测
    python upnp_probe.py --map 3602 3478  # 顺便申请 TCP/UDP 端口映射
"""
import argparse
import re
import socket
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

SSDP_ADDR = ('239.255.255.250', 1900)
MCAST_TTL = 2

# 运营商大内网 / 私有地址段：出现这些就说明没有真公网 IP
CGNAT_HINTS = (
    ('100.64.', '运营商 CGNAT 大内网 (100.64/10)'),
    ('10.', '私有地址 (10/8)'),
    ('192.168.', '私有地址 (192.168/16)'),
    ('172.16.', '私有地址 (172.16/12)'),
    ('172.17.', '私有地址 (172.16/12)'),
    ('172.18.', '私有地址 (172.16/12)'),
    ('172.19.', '私有地址 (172.16/12)'),
    ('172.2', '私有地址 (172.16/12)'),
    ('172.30.', '私有地址 (172.16/12)'),
    ('172.31.', '私有地址 (172.16/12)'),
)


def log(msg=''):
    print(msg, flush=True)


def ssdp_discover(timeout=4.0):
    """M-SEARCH 找 IGD 设备，返回去重后的 LOCATION 列表"""
    targets = [
        'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
        'urn:schemas-upnp-org:service:WANIPConnection:1',
        'urn:schemas-upnp-org:service:WANPPPConnection:1',
        'upnp:rootdevice',
    ]
    locs = []
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, MCAST_TTL)
    except OSError:
        pass
    s.settimeout(0.6)

    for st in targets:
        msg = (
            'M-SEARCH * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            f'ST: {st}\r\n'
            '\r\n'
        ).encode()
        try:
            s.sendto(msg, SSDP_ADDR)
        except OSError as e:
            log(f'  发送失败（{st}）：{e}')
            continue
        end = time.time() + timeout / len(targets)
        while time.time() < end:
            try:
                data, _addr = s.recvfrom(65507)
            except socket.timeout:
                break
            m = re.search(rb'LOCATION:\s*(\S+)', data, re.I)
            if m:
                loc = m.group(1).decode('utf-8', 'replace').strip()
                if loc not in locs:
                    locs.append(loc)
    s.close()
    return locs


def fetch_desc(loc):
    try:
        with urllib.request.urlopen(loc, timeout=6) as r:
            return r.read().decode('utf-8', 'replace')
    except Exception as e:
        log(f'  拉取设备描述失败 {loc}：{e}')
        return None


def find_wan_service(xml_text, base_url):
    """在设备描述里找 WANIPConnection / WANPPPConnection 的 controlURL"""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as e:
        log(f'  XML 解析失败：{e}')
        return None

    ns = '{urn:schemas-upnp-org:device-1-0}'
    for svc in root.iter(f'{ns}service'):
        stype = (svc.findtext(f'{ns}serviceType') or '').strip()
        if 'WANIPConnection' in stype or 'WANPPPConnection' in stype:
            ctrl = (svc.findtext(f'{ns}controlURL') or '').strip()
            stype_ver = stype
            if not ctrl:
                continue
            if ctrl.startswith('http'):
                url = ctrl
            elif ctrl.startswith('/'):
                m = re.match(r'(https?://[^/]+)', base_url)
                url = (m.group(1) if m else base_url) + ctrl
            else:
                url = base_url.rstrip('/') + '/' + ctrl
            return stype_ver, url
    return None


def soap_call(ctrl_url, service_type, action, body_xml, timeout=6):
    env = (
        '<?xml version="1.0"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        f'<u:{action} xmlns:u="{service_type}">{body_xml}</u:{action}>'
        '</s:Body></s:Envelope>'
    ).encode()
    req = urllib.request.Request(ctrl_url, data=env, method='POST')
    req.add_header('Content-Type', 'text/xml; charset="utf-8"')
    req.add_header('SOAPAction', f'"{service_type}#{action}"')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def get_external_ip(ctrl_url, service_type):
    try:
        txt = soap_call(ctrl_url, service_type, 'GetExternalIPAddress', '')
    except Exception as e:
        log(f'  GetExternalIPAddress 调用失败：{e}')
        return None
    m = re.search(r'<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>', txt)
    return m.group(1).strip() if m else None


def add_port_mapping(ctrl_url, service_type, port, proto, internal_ip, desc):
    body = (
        f'<NewRemoteHost></NewRemoteHost>'
        f'<NewExternalPort>{port}</NewExternalPort>'
        f'<NewProtocol>{proto}</NewProtocol>'
        f'<NewInternalPort>{port}</NewInternalPort>'
        f'<NewInternalClient>{internal_ip}</NewInternalClient>'
        f'<NewEnabled>1</NewEnabled>'
        f'<NewPortMappingDescription>{desc}</NewPortMappingDescription>'
        f'<NewLeaseDuration>0</NewLeaseDuration>'
    )
    try:
        soap_call(ctrl_url, service_type, 'AddPortMapping', body, timeout=8)
        return True, ''
    except Exception as e:
        return False, str(e)


def local_ip_toward(host='223.5.5.5'):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 80))
        return s.getsockname()[0]
    except OSError:
        return ''
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', nargs='*', type=int, default=None,
                    help='要申请的端口列表（TCP+UDP 各一条）')
    ap.add_argument('--ip', default=None, help='手动指定内网IP（默认自动取本机）')
    ap.add_argument('--desc', default='xiaozhi-im', help='映射描述')
    args = ap.parse_args()

    log('=' * 58)
    log('  UPnP 探测：路由器 WAN 口到底是不是公网 IP')
    log('=' * 58)

    log('\n[1] SSDP 发现网关 ...')
    locs = ssdp_discover()
    if not locs:
        log('  ✗ 没收到任何 UPnP 响应。')
        log('    - 路由器可能关闭了 UPnP，或做了 VLAN 隔离')
        log('    - 请手动登录路由器，直接看「WAN 口 IP」一栏')
        return 2
    for l in locs:
        log(f'  · {l}')

    log('\n[2] 定位 WAN 连接服务 ...')
    target = None
    for loc in locs:
        xml_text = fetch_desc(loc)
        if not xml_text:
            continue
        found = find_wan_service(xml_text, loc)
        if found:
            target = found
            log(f'  ✓ {found[0]}')
            log(f'    control: {found[1]}')
            break
    if not target:
        log('  ✗ 网关未暴露 WANIPConnection（常见于光猫桥接 / 路由器未开放 IGD）')
        return 2

    service_type, ctrl_url = target

    log('\n[3] 询问公网 IP ...')
    ext = get_external_ip(ctrl_url, service_type)
    if not ext:
        log('  ✗ 路由器没有返回 ExternalIPAddress')
        return 2
    log(f'  路由器 WAN 口 IP = {ext}')

    log('\n[4] 结论')
    bad = next((why for pfx, why in CGNAT_HINTS if ext.startswith(pfx)), None)
    if bad:
        log(f'  ✗ {ext} 属于「{bad}」')
        log('    -> 没有真正的公网 IPv4，飞牛自建 TURN 从公网进不来。')
        log('    -> 中继应部署在有公网 IP 的云服务器上。')
    else:
        log(f'  ✓ {ext} 是公网地址，路由器 WAN 口就是公网 IP。')
        log('    -> 飞牛自建 TURN 可行，只差端口映射。')

    if args.map:
        log('\n[5] 申请端口映射 ...')
        internal = args.ip or local_ip_toward()
        if not internal:
            log('  ✗ 取不到本机内网 IP，跳过')
            return 1
        log(f'  内网目标: {internal}')
        for port in args.map:
            for proto in ('TCP', 'UDP'):
                ok, err = add_port_mapping(ctrl_url, service_type, port, proto,
                                           internal, args.desc)
                log(f'  {proto} {port} -> {"✓ 成功" if ok else "✗ 失败：" + err}')
    log()
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
