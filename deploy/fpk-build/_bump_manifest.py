# -*- coding: utf-8 -*-
"""把 fpk manifest 提到 0.21.3，并补齐 0.19.0 之后的更新说明。

为什么要单独一个脚本而不用 Edit：
  · manifest 是 fnpack 的 key=value 解析器逐行读的。第 4 行的 desc 是一条 1.4 万字
    的超长行，第 5 行是它的**续行却没有 '='** —— fnpack 会直接抛
    "key-value delimiter not found" 并把整行糊出来，不说行号。
    人工 Edit 很容易又把它拆成两行。
  · 本次要把新说明也拼进去，等于连续两次动那条超长行，用脚本更可控、可复现。

用法：python _bump_manifest.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
MANIFEST = os.path.join(HERE, 'manifest')
SERVER_PKG = os.path.join(ROOT, 'server', 'package.json')

NEW_BLOCKS = [
    ('0.19.0', [
        '(131) <b>开放 API 签名通道</b>：长期令牌那套的问题是泄露后可无限重放、也看不出是谁在调。'
        '新增第二条通道 —— 每个对接方发一对 app_id / app_secret，每次请求<b>现算 HMAC 签名</b>，'
        '待签串含方法、路径、查询串、时间戳、随机数和请求体摘要；secret 以密文存储，'
        '明文只在发放那一次出现；轮换留 24 小时宽限期，不留宽限就没人敢按那个按钮',
    ]),
    ('0.20.0', [
        '(132) <b>培训中心</b>：一条完整闭环 —— 课程 → 章节 → 课时（记进度）→ 章节考试（判分留档），'
        '考试机会在开始那一刻就扣掉、不达标不放行、多选题全对才得分；成绩提交即按当时的题判分，'
        '之后改题不影响已存成绩。课件走 Range 请求，NAS 上的大视频可以拖着看'
    ]),
    ('0.21.0', [
        '(133) <b>应用中心「管理」抽屉</b>：内置应用可<b>改名 / 换图标 / 调排序 / 改参数 / 整应用停用</b>，'
        '还能看数据概览与导出。客户端不用改也不用重装 —— 它本来就按服务端下发的清单渲染。'
        '停用是后端逐条拦（返回 403），不是前端藏图标，老客户端缓存页面也打不进去',
    ]),
    ('0.21.1', [
        '(134) <b>库房减货独立成入口</b>：从「盘点」页里的一个图标改成工作台上的独立卡片，'
        '点进去就是减货 —— 之前藏在别人页面里等于没入口',
    ]),
    ('0.21.2', [
        '(135) <b>简易盘点通道</b>：新开一条干活型的盘点通道 —— 先导入本轮要盘的商品清单，'
        '再一趟一趟盘，最后导出全量盘点数据单（盘到的带数量，没盘到的是 0）。'
        '与原来制度化盘点的点位互比并存，两者不冲突',
    ]),
    ('0.21.3', [
        '(136) <b>简易盘点补齐到可用</b>：待盘清单支持上传本轮商品，盘点过程接摄像头扫码，'
        '明细页可切换「还没盘 / 本趟已录」引导接着扫；差异复盘趟只收差异集。'
        '另外管理台应用中心可直接 ↑↓ 调排序，行内按钮在深色主题下也看得清'
    ]),
]


def main():
    with open(SERVER_PKG, encoding='utf-8') as f:
        srv = json.load(f).get('version', '')
    if not srv:
        sys.exit('读不到 server/package.json 的版本')

    with open(MANIFEST, encoding='utf-8', newline='') as f:
        lines = f.read().split('\n')

    # 1) 把没有 '=' 的续行并回上一条（fnpack 要求每行都是 key=value）
    merged = []
    for l in lines:
        if not l.strip():
            continue
        if '=' in l:
            merged.append(l)
        else:
            body = l[1:] if l.startswith('<br>') else l
            merged[-1] = merged[-1] + '<br>' + body if merged else l
    print('合并续行：%d 行 -> %d 行' % (len([x for x in lines if x.strip()]), len(merged)))

    kv = {}
    for l in merged:
        if '=' in l:
            kv[l.split('=', 1)[0].strip()] = l

    old_ver = None
    for i, l in enumerate(merged):
        if l.startswith('version='):
            old_ver = l.split('=', 1)[1]
            merged[i] = 'version=%s' % srv
            break
    if old_ver is None:
        sys.exit('manifest 里找不到 version=')

    # 2) desc 追加本版之后的更新说明
    di = next(i for i, l in enumerate(merged) if l.startswith('desc='))
    desc = merged[di].split('=', 1)[1]
    if '【v%s 更新】' % srv in desc:
        print('desc 里已经有 v%s 更新说明，跳过追加' % srv)
    else:
        add = ''
        for ver, items in NEW_BLOCKS:
            if ver > old_ver:
                add += '<br>【v%s 更新】<br>' % ver + '<br>'.join(items)
        if add:
            desc += add
            merged[di] = 'desc=' + desc
            print('desc 追加 %d 字（%s 之后的更新说明）' % (len(add), old_ver))

    with open(MANIFEST, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(merged))
    print('manifest 已更新：version %s -> %s' % (old_ver, srv))


if __name__ == '__main__':
    main()
