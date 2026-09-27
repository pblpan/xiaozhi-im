# -*- coding: utf-8 -*-
"""以管理员身份实测线上管理台的「工作台顶部公告」卡片。

不碰密码：在容器里用服务端同一把 JWT_SECRET 签一个 10 分钟有效的 admin token，
注入浏览器 localStorage 后刷新 —— 等价于"已登录的管理员打开管理台"。
token 只在本进程内流转，不打印、不落盘。
"""
import re, sys, tempfile, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS
import paramiko
from playwright.sync_api import sync_playwright

CHROME = r'C:\Users\pblpa\AppData\Local\ms-playwright\chromium-1140\chrome-win\chrome.exe'
BASE = 'http://192.168.31.44:3602'
BASE_DIR = r'C:\Users\pblpa\WorkBuddy\2026-09-08-11-01-42\xiaozhi-im\deploy'

# ---- 1. 容器里签 token ----
node_src = """
// ⚠️ 脚本会跑到 /tmp 下执行，模块解析从 /tmp 往上找 node_modules 找不到，
//    所以这里必须写绝对路径
const jwt = require('/app/node_modules/jsonwebtoken');
const config = require('/app/src/config.js');
const t = jwt.sign(
  { uid: 1, role: 'admin', exp: Math.floor(Date.now() / 1000) + 600 },
  config.JWT_SECRET
);
console.log('TOKEN=' + t);
console.log('SECRET_LEN=' + String(config.JWT_SECRET.length));
"""
local_node = os.path.join(BASE_DIR, '_mk_token.js')
open(local_node, 'w', encoding='utf-8').write(node_src)

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, banner_timeout=15, auth_timeout=15)
sftp = cli.open_sftp()
remote = '/tmp/_mk_token.js'
sftp.put(local_node, remote)
cmd = ('echo "%s" | sudo -S docker cp %s xiaozhi-im:%s >/dev/null && '
       'echo "%s" | sudo -S docker exec xiaozhi-im node %s 2>&1') % (PASS, remote, remote, PASS, remote)
_, o, _ = cli.exec_command(cmd, timeout=120, get_pty=True)
out = o.read().decode('utf-8', 'replace')
sftp.close(); cli.close()
os.remove(local_node)

m = re.search(r'TOKEN=([\w\-\.]+)', out)
if not m:
    print('签 token 失败，容器返回：')
    print(out[-800:])
    sys.exit(1)
TOKEN = m.group(1)
print('[token] 已签，长度 %d（10 分钟有效）' % len(TOKEN))

# ---- 2. 浏览器实测 ----
NET = []


def on_resp(r):
    if '/api/admin/apps' in r.url:
        body = ''
        try:
            body = r.text()
        except Exception:
            body = '<读不到>'
        NET.append((r.status, r.url.replace(BASE, ''), body[:300]))


with sync_playwright() as pw:
    br = pw.chromium.launch(executable_path=CHROME, args=['--no-sandbox'])
    ctx = br.new_context(viewport={'width': 1680, 'height': 1050})
    pg = ctx.new_page()
    pg.on('response', on_resp)
    pg.on('pageerror', lambda e: print('[pageerror]', str(e)[:300]))

    pg.goto(BASE + '/admin/', wait_until='domcontentloaded')
    pg.evaluate("(t) => localStorage.setItem('xz_token', t)", TOKEN)
    pg.reload(wait_until='domcontentloaded')
    pg.wait_for_timeout(2500)

    print('[是否登录]', pg.evaluate("() => !!document.querySelector('.el-menu-item')"))
    menus = [m.strip() for m in pg.locator('.el-menu-item').all_text_contents() if m.strip()]
    print('[菜单]', ' | '.join(menus)[:500])

    # 「动态模块」是二级折叠项，直接点会"元素不可见"。
    # 先让页面自报它挂在哪个父菜单下，再 hover 那个父级把它展开。
    info = pg.evaluate("""() => {
      const it = [...document.querySelectorAll('.el-menu-item')]
        .find(e => (e.textContent || '').includes('动态模块'));
      if (!it) return { found: false };
      const sub = it.closest('.el-sub-menu');
      const title = sub && sub.querySelector(':scope > .el-sub-menu__title');
      // Vue 实例挂在哪个容器上
      let holder = null;
      for (let e = it; e; e = e.parentElement) {
        if (e.__vue_app__) { holder = e.id || e.tagName; break; }
      }
      return { found: true, parent: title ? title.innerText.trim() : '(无父级)', holder: holder || '(未找到 __vue_app__)' };
    }""")
    print('[菜单结构] =', info)
    if info.get('found') and info.get('parent'):
        pg.locator('.el-sub-menu__title', has_text=info['parent']).first.click()
        pg.wait_for_timeout(1200)
        try:
            pg.locator('.el-menu-item', has_text='动态模块').first.click(timeout=8000)
            print('[切页] 已点击「动态模块」')
        except Exception as e:
            print('[切页] 点击失败:', str(e)[:120])
    pg.wait_for_timeout(3500)

    # 公告卡片
    hdr = pg.locator('text=工作台顶部公告')
    print('[公告卡片标题] 数量 =', hdr.count())

    # 公告表格行数：整页里找含「生效中」的行
    rows = pg.locator('.el-table__body-wrapper .el-table__row')
    print('[全页表格行] =', rows.count())
    hit = rows.filter(has_text='生效中')
    print('[含「生效中」的行] =', hit.count())
    if hit.count():
        print('    内容 =', hit.first.inner_text().replace('\n', ' / ')[:160])

    # 空态提示
    empty = pg.locator('.el-table__empty-text')
    if empty.count():
        print('[表格空态] =', empty.first.inner_text()[:80])

    # 输入测试 A：顶部「发布」输入框
    inp = pg.locator('input[placeholder*="要所有人看见的一句话"]')
    print('[发布输入框] 数量 =', inp.count())
    if inp.count():
        inp.first.click()
        inp.first.type('实测输入', delay=80)
        print('[发布框打字后] =', repr(inp.first.input_value()))

    # 输入测试 B：表格里「内容」列的行内输入框（龙哥说的"下面内容里面"）
    row = rows.filter(has_text='生效中').first
    if row.count():
        cell_input = row.locator('.el-table-column, td').first.locator('input').first
        rg = cell_input
        print('[内容列输入框] 数量 =', rg.count())
        if rg.count():
            before = rg.input_value()
            print('[内容列当前值] =', repr(before))
            rg.click()
            rg.fill('')
            rg.type('改过的公告', delay=80)
            print('[内容列打字后] =', repr(rg.input_value()))
            # 开关
            sw = row.locator('.el-switch').first
            if sw.count():
                print('[启用开关] disabled =', sw.first.is_disabled())
            # 排序数字框
            num = row.locator('.el-input-number input').first
            if num.count():
                print('[排序框] 值 =', num.input_value(), '| disabled =', num.is_disabled())
        else:
            print('[内容列] 没找到 input —— 这一列渲染不出输入框')
    else:
        print('[公告行] 没找到，无法测行内编辑')

    # 看这一列底下的 DOM，找"不能输入"的证据
    try:
        cellhtml = pg.evaluate("""() => {
          const row = [...document.querySelectorAll('.el-table__body-wrapper .el-table__row')]
            .find(r => r.innerText.includes('生效中'));
          if (!row) return '(无行)';
          const tds = [...row.querySelectorAll('td')];
          return tds.map(td => td.innerText.trim().slice(0, 20) + '||' + (td.querySelector('input') ? 'INPUT:' + (td.querySelector('input').disabled ? 'disabled' : 'ok') : 'no-input')).join(' || ');
        }""")
        print('[行内 DOM]', cellhtml[:600])
    except Exception as e:
        print('[行内 DOM] 读取失败:', str(e)[:120])

    pg.screenshot(path='/tmp/xz_notice.png', full_page=True)
    br.close()

print('\n---- /api/admin/apps 相关响应 ----')
for s, u, b in NET:
    print('[%s] %s' % (s, u))
    if b:
        try:
            import json
            j = json.loads(b)
            print('     keys =', json.dumps(list(j.keys()), ensure_ascii=False))
            print('     notices =', json.dumps(j.get('notices'), ensure_ascii=False)[:200])
        except Exception:
            print('     ', b[:200])
print('\n[完成] 截图 /tmp/xz_notice.png')
