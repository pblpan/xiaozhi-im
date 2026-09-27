# -*- coding: utf-8 -*-
"""验收「工作台顶部公告」的修复：发布后列表必须立刻出现。

顺带把上一轮测试误改的公告文本复原。
流程：切到动态模块 → 复原文本 → 发布一条测试公告 → 立刻数行数 → 删除 → 收尾核对。
"""
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS
import paramiko
from playwright.sync_api import sync_playwright

CHROME = r'C:\Users\pblpa\AppData\Local\ms-playwright\chromium-1140\chrome-win\chrome.exe'
BASE = 'http://192.168.31.44:3602'
BASE_DIR = r'C:\Users\pblpa\WorkBuddy\2026-09-08-11-01-42\xiaozhi-im\deploy'
ORIG = '工作台排版测试'
TESTTXT = '验收测试-可删'

# ---- 签一个临时 admin token ----
node_src = """
const jwt = require('/app/node_modules/jsonwebtoken');
const config = require('/app/src/config.js');
console.log('TOKEN=' + jwt.sign(
  { uid: 1, role: 'admin', exp: Math.floor(Date.now() / 1000) + 600 },
  config.JWT_SECRET));
"""
local_node = os.path.join(BASE_DIR, '_mk_token.js')
open(local_node, 'w', encoding='utf-8').write(node_src)
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, banner_timeout=15, auth_timeout=15)
sftp = cli.open_sftp()
sftp.put(local_node, '/tmp/_mk_token.js')
cmd = ('echo "%s" | sudo -S docker cp /tmp/_mk_token.js xiaozhi-im:/tmp/_mk_token.js >/dev/null && '
       'echo "%s" | sudo -S docker exec xiaozhi-im node /tmp/_mk_token.js 2>&1') % (PASS, PASS)
_, o, _ = cli.exec_command(cmd, timeout=120, get_pty=True)
out = o.read().decode('utf-8', 'replace')
sftp.close(); cli.close(); os.remove(local_node)
m = re.search(r'TOKEN=([\w\-\.]+)', out)
if not m:
    print('签 token 失败:', out[-500:]); sys.exit(1)
TOKEN = m.group(1)
print('[token] ok (%d 字符, 10 分钟)' % len(TOKEN))

FAIL = []


def check(name, ok, extra=''):
    print(('  [PASS] ' if ok else '  [FAIL] ') + name + ((' — ' + str(extra)) if extra else ''))
    if not ok:
        FAIL.append(name)


with sync_playwright() as pw:
    br = pw.chromium.launch(executable_path=CHROME, args=['--no-sandbox'])
    ctx = br.new_context(viewport={'width': 1680, 'height': 1050})
    pg = ctx.new_page()
    errs = []
    pg.on('pageerror', lambda e: errs.append(str(e)[:200]))

    pg.goto(BASE + '/admin/', wait_until='domcontentloaded')
    pg.evaluate("(t) => localStorage.setItem('xz_token', t)", TOKEN)
    pg.reload(wait_until='domcontentloaded')
    pg.wait_for_timeout(2000)

    # 展开「业务模块」→ 点「动态模块」
    pg.locator('.el-sub-menu__title', has_text='业务模块').first.click()
    pg.wait_for_timeout(1000)
    pg.locator('.el-menu-item', has_text='动态模块').first.click()
    pg.wait_for_timeout(3500)

    card = pg.locator('.el-card').filter(has_text='工作台顶部公告').last
    rows = card.locator('.el-table__body-wrapper .el-table__row')

    print('\n[1] 打开页面就能看见已发布的公告')
    n0 = rows.count()
    check('列表有已发布内容', n0 >= 1, '行数=%d' % n0)

    # 复原文本
    if n0 >= 1:
        ci = rows.first.locator('td').first.locator('input').first
        cur = ci.input_value()
        print('    当前文本 =', repr(cur))
        if cur != ORIG:
            ci.click(); ci.fill(ORIG)
            ci.press('Tab')
            pg.wait_for_timeout(1600)
            after = rows.first.locator('td').first.locator('input').first.input_value()
            check('行内编辑能改内容', after == ORIG, '改为 %r' % after)
        else:
            print('    （文本本来就是对的，跳过复原）')

    print('\n[2] 发布一条新公告 → 列表必须立刻出现（这就是龙哥踩的坑）')
    inp = card.locator('input[placeholder*="要所有人看见的一句话"]').first
    inp.click(); inp.fill(TESTTXT)
    card.locator('button', has_text='发布').first.click()
    pg.wait_for_timeout(2000)
    n1 = rows.count()
    texts = [rows.nth(i).locator('td').first.locator('input').first.input_value()
             for i in range(n1)]
    check('发布后列表立刻多一行', n1 == n0 + 1, '发布前 %d → 发布后 %d，内容=%s' % (n0, n1, texts))
    check('新公告真的在列表里', TESTTXT in texts, texts)

    print('\n[3] 停用 / 删除也要立刻反映')
    line = rows.filter(has_text='生效中').first
    # 找到测试那行：按内容匹配
    tgt = None
    for i in range(n1):
        if rows.nth(i).locator('td').first.locator('input').first.input_value() == TESTTXT:
            tgt = rows.nth(i)
            break
    if tgt is not None:
        tgt.locator('button', has_text='删除').first.click()
        pg.wait_for_timeout(1600)
        # 有确认框就点确定
        try:
            pg.locator('.el-message-box__btns button', has_text='确定').first.click(timeout=2500)
            pg.wait_for_timeout(1600)
        except Exception:
            pass
        n2 = rows.count()
        left = [rows.nth(i).locator('td').first.locator('input').first.input_value()
                for i in range(n2)]
        check('删除后行数减回去', n2 == n0, '删除后 %d 行，内容=%s' % (n2, left))
    else:
        print('    （没找到测试行，跳过删除）')

    print('\n[4] 收尾：列表应只剩原来那条，且文本已复原')
    n3 = rows.count()
    final = [rows.nth(i).locator('td').first.locator('input').first.input_value()
             for i in range(n3)]
    check('最终只剩 1 条', n3 == 1, final)
    check('文本已复原', ORIG in final, final)
    check('页面无 JS 报错', not errs, errs[:2])

    pg.screenshot(path='/tmp/xz_notice_fixed.png', full_page=True)
    br.close()

print('\n==== 结果 ====')
print('全部通过' if not FAIL else ('未通过: ' + ' / '.join(FAIL)))
print('截图 /tmp/xz_notice_fixed.png')
