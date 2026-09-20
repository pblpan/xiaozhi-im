# -*- coding: utf-8 -*-
"""M1 盘点服务端「真写库」冒烟 —— 不只是探 401，是把三遍制跑一遍。

🔴 为什么要有这个脚本：
   只探 `curl /api/stocktake/zones 返回 401` 只能证明**路由挂上了**，
   证明不了「上传能落库 / 抽盘的复核清单真的拦得住 / 漏盘算不算差异」。
   部署完不做这一步，真机验收时才发现"传上去 0 行"就晚了。

🔴 差异口径（2026-09-19 改，客户端/服务端必须一致）：
   门店的系统里**没有可用的库存账面**（泰格库所有库存表都是空的），
   所以差异不是"实盘 vs 账面"，而是**三遍平行互比**：
       复盘比初盘、抽盘比复盘，数量对不上 → 差异；
       上一遍盘过、这一遍没扫到（**漏盘**）→ 也是差异；
       初盘没有上一遍可比 → 差异恒为 0。
   `account_qty` 保留，只作参考列，不参与判定。
   只有**抽盘**限"复核清单"，复盘不限（复盘的价值就在于不知道哪里会错）。

覆盖的判据：
   1. 建盘点位 / 库位 / 开初盘单
   2. 初盘上传 5 行 → 单据级差异 0（没有参照）
   3. 复盘**不设限**：传"两遍一致"的商品也必须成功   ← 🔴 反向测试
   4. 阶段小结：复盘差异 3（1 条数量对不上 + 2 条漏盘）、失误 1  ← 🔴 漏盘判据
   5. 抽盘传**清单外**的商品 → 400 not_in_diff_set      ← 🔴 反向测试
   6. 抽盘传**漏盘**的条码 → 放行（漏盘必须进复核清单）  ← 🔴 漏盘判据
   7. 重传已归档的单 → 409 already_uploaded
   8. 收尾：删掉整个测试点位（级联删单据/明细/绑定），不留垃圾

用法：
   python deploy/_m1_smoke.py
   （管理员密码自动从桌面那份「小智管理台新密码-请勿外传.txt」读，不打印）
"""
import json
import os
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402

BASE = 'http://127.0.0.1:3602'
ZONE = 'M1SMOKE'
PASS_FILE = r'D:\Users\pblpa\Desktop\小智 IM\小智管理台新密码-请勿外传.txt'

_results = []


def check(name, ok, detail=''):
    _results.append((name, ok, detail))
    print('  %-44s %s %s' % (name, 'OK  ' if ok else '<<<<', detail))
    return ok


def read_admin_password():
    if os.environ.get('M1_ADMIN_PASS'):
        return os.environ['M1_ADMIN_PASS'].strip()
    # 🔴 那份 txt 不止一行（有标题、分隔线、说明），**第一行不是密码**。
    #    真正的密码在「新密码 xxx」这一行 —— 直接取第一行会拿到标题，
    #    表现是登录 401，很容易被误判成"服务端没部署好"。
    for enc in ('utf-8', 'gbk'):
        try:
            with open(PASS_FILE, encoding=enc) as f:
                lines = [l.strip() for l in f]
        except (OSError, UnicodeDecodeError):
            continue
        for l in lines:
            if l.startswith('新密码'):
                # 行长这样：`新密码   :   <密码>`（中间还有个冒号分隔），
                # 所以**取最后一个空白分隔的 token**，不能取"第一个空格之后"。
                tok = l.split()
                if len(tok) >= 2:
                    return tok[-1]
    return ''


def main():
    admin_pw = read_admin_password()
    if not admin_pw:
        print('❌ 拿不到管理员密码：%s（或设环境变量 M1_ADMIN_PASS）' % PASS_FILE)
        return 2
    print('管理员密码长度: %d（不打印）' % len(admin_pw))

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20)
    token = None
    sheet1 = sheet2 = sheet3 = None
    try:
        def api(method, path, body=None):
            """在飞牛上 curl 本机端口，返回 (http_code, dict|None, raw)"""
            cmd = "curl -s -m 10 -w '\\n%%{http_code}' -X %s %s%s" % (method, BASE, path)
            if token:
                cmd += " -H 'Authorization: Bearer %s'" % token
            if body is not None:
                payload = json.dumps(body, ensure_ascii=False).replace("'", "'\\''")
                cmd += " -H 'Content-Type: application/json' -d '%s'" % payload
            _, so, se = c.exec_command(cmd, timeout=60)
            raw = so.read().decode('utf-8', 'replace').strip()
            err = se.read().decode('utf-8', 'replace').strip()
            if err and 'Could not chdir' not in err:
                print('    [curl stderr] ' + err[:200])
            lines = raw.rsplit('\n', 1)
            if len(lines) != 2:
                return 0, None, raw
            text, code = lines[0], lines[1].strip()
            try:
                return int(code), json.loads(text) if text else None, text
            except ValueError:
                return int(code) if code.isdigit() else 0, None, text

        def phase_of(zcode, p):
            """取点位某阶段的小结（差异里含漏盘，所以这个数比"数量对不上"的大）"""
            code, js, _ = api('GET', '/api/stocktake/zone/%s' % zcode)
            for x in ((js or {}).get('phases') or []):
                if x.get('phase') == p:
                    return x
            return {}

        print('\n=== 1. 登录 ===')
        code, js, raw = api('POST', '/api/auth/login', {'username': 'admin', 'password': admin_pw})
        if not check('登录拿 token', code == 200 and js and js.get('token'),
                     'HTTP %s' % code):
            print('  原始返回: ' + raw[:200])
            return 1
        token = js['token']

        print('\n=== 2. 盘点位 / 库位 ===')
        # 先清掉上一轮可能残留的点位（脚本中途挂掉时留下的），保证幂等
        api('DELETE', '/api/stocktake/zone/%s' % ZONE)
        code, js, _ = api('POST', '/api/stocktake/zone',
                          {'zone_code': ZONE, 'zone_name': 'M1部署自检点位'})
        check('建盘点位 %s' % ZONE, code == 200 and js and js['zone']['zone_code'] == ZONE, 'HTTP %s' % code)
        code, js, _ = api('POST', '/api/stocktake/location',
                          {'zone_code': ZONE, 'loc_code': ZONE + '-L1', 'loc_name': 'A架1层'})
        check('建库位 %s-L1' % ZONE, code == 200, 'HTTP %s' % code)

        print('\n=== 3. 开初盘单 + 上传 5 行 ===')
        code, js, _ = api('POST', '/api/stocktake/sheet',
                          {'zone_code': ZONE, 'phase': 1, 'device_id': 'm1-smoke'})
        if not check('开初盘单(phase=1)', code == 200 and js and js['sheet']['sheet_no'], 'HTTP %s' % code):
            return 1
        sheet1 = js['sheet']['sheet_no']
        print('    单号: ' + sheet1)
        # M1B001/003/004 在两遍之间保持一致 → 它们只会以"漏盘"身份进差异集
        rows1 = [
            {'barcode': 'M1B001', 'qty': 10, 'account_qty': 10, 'loc_code': ZONE + '-L1'},
            {'barcode': 'M1B002', 'qty': 8, 'account_qty': 10, 'loc_code': ZONE + '-L1'},
            {'barcode': 'M1B003', 'qty': 5, 'loc_code': ZONE + '-L1'},
            {'barcode': 'M1B004', 'qty': 7, 'account_qty': 7},
            {'barcode': 'M1B005', 'qty': 3, 'account_qty': 9, 'loc_code': ZONE + '-L1'},
        ]
        code, js, raw = api('POST', '/api/stocktake/sheet/%s/upload' % sheet1,
                            {'zone': {'zone_code': ZONE, 'zone_name': 'M1部署自检点位'},
                             'phase': 1, 'rows': rows1, 'device_id': 'm1-smoke'})
        if not check('初盘上传 5 行', code == 200 and js and js.get('accepted') == 5,
                     'HTTP %s accepted=%s' % (code, js and js.get('accepted'))):
            print('  原始返回: ' + raw[:300])

        print('\n=== 4. 初盘差异必须为 0（没有上一遍可比）===')
        code, js, raw = api('GET', '/api/stocktake/sheet/%s' % sheet1)
        s = (js or {}).get('summary') or {}
        check('明细 5 行', code == 200 and s.get('kinds') == 5, 'kinds=%s' % s.get('kinds'))
        check('单据级差异 0（初盘不比账面）', s.get('diff') == 0, 'diff=%s' % s.get('diff'))
        check('账面缺失（账上无此商品）1 条', s.get('unknown') == 1, 'unknown=%s' % s.get('unknown'))
        check('未绑库位 1 条', s.get('unbound') == 1, 'unbound=%s' % s.get('unbound'))

        print('\n=== 5. 复盘：不设限，「两遍一致」的商品也必须能进（🔴 反向测试）===')
        code, js, _ = api('POST', '/api/stocktake/sheet',
                          {'zone_code': ZONE, 'phase': 2, 'device_id': 'm1-smoke'})
        if not check('开复盘单(phase=2)', code == 200 and js and js['sheet']['sheet_no'], 'HTTP %s' % code):
            return 1
        sheet2 = js['sheet']['sheet_no']
        print('    单号: ' + sheet2)
        code, js, raw = api('POST', '/api/stocktake/sheet/%s/upload' % sheet2,
                            {'zone': {'zone_code': ZONE}, 'phase': 2,
                             'rows': [{'barcode': 'M1B002', 'qty': 10, 'account_qty': 10},   # 8 → 10，对不上
                                      {'barcode': 'M1B005', 'qty': 3, 'account_qty': 9},    # 3 → 3，两遍一致
                                      {'barcode': 'M1B004', 'qty': 7, 'account_qty': 7}]})   # 7 → 7，两遍一致
        check('复盘收下"两遍一致"的商品（复盘本来就该重新全盘一遍）',
              code == 200 and js and js.get('accepted') == 3,
              'HTTP %s accepted=%s' % (code, js and js.get('accepted')))
        if code != 200:
            print('  ❌ 复盘被差异集挡住了，三遍制退化成走过场。原始返回: ' + raw[:300])

        print('\n=== 6. 阶段小结：复盘差异 3 = 1 条对不上 + 2 条漏盘（🔴 漏盘判据）===')
        p1 = phase_of(ZONE, 1)
        p2 = phase_of(ZONE, 2)
        check('初盘：5 品种 / 差异 0 / 失误 0',
              p1.get('kinds') == 5 and p1.get('diff') == 0 and p1.get('mistakes') == 0,
              json.dumps(p1, ensure_ascii=False)[:120])
        # 复盘只扫了 M1B002/004/005：
        #   M1B002  8 → 10      = 数量对不上（1 条）
        #   M1B005  3 → 3       = 一致，不算
        #   M1B004  7 → 7       = 一致，不算
        #   M1B001 / M1B003     = 初盘有、复盘没扫 → 漏盘（2 条）
        check('复盘：3 品种 / 差异 3（含 2 条漏盘）/ 失误 1',
              p2.get('kinds') == 3 and p2.get('diff') == 3 and p2.get('mistakes') == 1,
              json.dumps(p2, ensure_ascii=False)[:160])
        if p2.get('diff') != 3:
            print('  ❌ 差异里没算漏盘（只从本阶段的行里挑差异就会漏掉'
                  '"上一遍有、这一遍没扫到"的那两行）。')

        print('\n=== 7. 抽盘：清单外的商品必须被拒（🔴 反向测试）===')
        code, js, _ = api('POST', '/api/stocktake/sheet',
                          {'zone_code': ZONE, 'phase': 3, 'device_id': 'm1-smoke'})
        if not check('开抽盘单(phase=3)', code == 200 and js and js['sheet']['sheet_no'], 'HTTP %s' % code):
            return 1
        sheet3 = js['sheet']['sheet_no']
        print('    单号: ' + sheet3)
        # M1B005 两遍都是 3 → 不在复核清单里
        code, js, raw = api('POST', '/api/stocktake/sheet/%s/upload' % sheet3,
                            {'zone': {'zone_code': ZONE}, 'phase': 3,
                             'rows': [{'barcode': 'M1B005', 'qty': 3, 'account_qty': 9}]})
        bcode = (js or {}).get('code') if isinstance(js, dict) else None
        check('抽盘塞"两遍一致"的 M1B005 → 400 not_in_diff_set',
              code == 400 and bcode == 'not_in_diff_set',
              'HTTP %s code=%s' % (code, bcode))
        if code != 400:
            print('  ❌ 抽盘的复核清单保护没生效！原始返回: ' + raw[:300])

        print('\n=== 8. 抽盘：漏盘的条码必须放行（🔴 漏盘判据）===')
        code, js, raw = api('POST', '/api/stocktake/sheet/%s/upload' % sheet3,
                            {'zone': {'zone_code': ZONE}, 'phase': 3,
                             'rows': [{'barcode': 'M1B001', 'qty': 9, 'account_qty': 10},
                                      {'barcode': 'M1B002', 'qty': 10, 'account_qty': 10}]})
        check('抽盘复核 漏盘(M1B001) + 对不上(M1B002) → accepted=2 且 diff_checked=true',
              code == 200 and js and js.get('accepted') == 2 and js.get('diff_checked') is True,
              'HTTP %s accepted=%s diff_checked=%s'
              % (code, js and js.get('accepted'), js and js.get('diff_checked')))
        if code != 200:
            print('  ❌ 漏盘没进复核清单：员工绕开不好盘的货架就查不出来了。原始返回: ' + raw[:300])

        print('\n=== 9. 已归档单默认拒绝覆盖（🔴 反向测试）===')
        code, js, raw = api('POST', '/api/stocktake/sheet/%s/upload' % sheet1,
                            {'zone': {'zone_code': ZONE}, 'phase': 1,
                             'rows': [{'barcode': 'M1B001', 'qty': 999, 'account_qty': 10}]})
        acode = (js or {}).get('code') if isinstance(js, dict) else None
        check('重传已上传单 → 409 already_uploaded',
              code == 409 and acode == 'already_uploaded', 'HTTP %s code=%s' % (code, acode))

        print('\n=== 10. 单据列表 ===')
        code, js, _ = api('GET', '/api/stocktake/sheets?zone=%s' % ZONE)
        n = (js or {}).get('total')
        check('列表能查到本点位的单', code == 200 and (n or 0) >= 3, 'HTTP %s total=%s' % (code, n))

    finally:
        print('\n=== 收尾：删掉测试点位（级联删单据/明细/绑定）===')
        if token:
            cmd = ("curl -s -m 10 -X DELETE %s/api/stocktake/zone/%s "
                   "-H 'Authorization: Bearer %s'" % (BASE, ZONE, token))
            _, so, _ = c.exec_command(cmd, timeout=60)
            print('  ' + so.read().decode('utf-8', 'replace').strip()[:200])
        else:
            print('  （没 token，跳过；请手工删 %s）' % ZONE)
        c.close()

    bad = [r for r in _results if not r[1]]
    print('\n判据 %d 条，失败 %d 条 → %s' % (len(_results), len(bad),
                                            'M1 服务端可用 ✅' if not bad else '有问题 ❌'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
