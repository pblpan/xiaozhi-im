#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""无头浏览器实测刚热更的管理台（CDP 方式，绕开 Playwright 对 msedge 的坑爹 launcher）：
   1) 读本地现签的 admin token（_verify_token.txt，避免明文口令）
   2) 手动用 --headless=new 起 msedge + --remote-debugging-port，connect_over_cdp 真登录态渲染
   3) 核验：顶栏版本号 / 「升级说明页网址（可选）」标签 / 帮助页搜索过滤 / 控制台无错误
   4) 截图存到桌面交付目录
"""
import os
import sys
import time
import json
import signal
import subprocess

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
URL = "http://192.168.31.44:3602/admin/"
OUTDIR = r"D:\Users\pblpa\Desktop\小智 IM"
PORT = 9333
import tempfile
PROFILE = tempfile.mkdtemp(prefix="xz_edge_")
os.makedirs(OUTDIR, exist_ok=True)

_proc = None


def launch_edge():
    global _proc
    args = [
        EDGE,
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-software-rasterizer",
        "--remote-debugging-port=%d" % PORT,
        "--user-data-dir=%s" % PROFILE,
        "about:blank",
    ]
    _proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # 等调试端口就绪
    for _ in range(40):
        try:
            import urllib.request
            with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % PORT, timeout=1) as r:
                data = json.loads(r.read().decode("utf-8"))
                if data.get("webSocketDebuggerUrl"):
                    return "http://127.0.0.1:%d" % PORT
        except Exception:
            time.sleep(0.5)
    raise SystemExit("msedge 调试端口没起来")


def cleanup():
    if _proc:
        try:
            _proc.terminate()
            _proc.wait(timeout=5)
        except Exception:
            try:
                _proc.kill()
            except Exception:
                pass


def _clear_proxy_env():
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
              "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"):
        os.environ.pop(k, None)


def main():
    _clear_proxy_env()
    tok_path = os.path.join(OUTDIR, "_verify_token.txt")
    with open(tok_path, encoding="utf-8") as f:
        token = f.read().strip()
    assert token, "读不到 token，先跑 _sign_token.py"
    print("[token] 长度", len(token))

    endpoint = launch_edge()
    print("[cdp] browser endpoint:", endpoint)

    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(endpoint)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900},
                                  ignore_https_errors=True)
        page = ctx.new_page()
        errors = []

        def on_pageerror(e):
            errors.append("PAGEERROR: " + str(e))

        def on_console(m):
            if m.type in ("error", "warning"):
                errors.append("CONSOLE[%s]: %s" % (m.type, m.text))

        page.on("pageerror", on_pageerror)
        page.on("console", on_console)

        page.goto(URL, wait_until="load", timeout=30000)
        page.evaluate("localStorage.setItem('xz_token', %r)" % token)
        page.reload(wait_until="networkidle", timeout=30000)
        page.wait_for_timeout(2500)

        def click_menu(text):
            ok = page.evaluate("""(t) => {
                const items = [...document.querySelectorAll('.el-menu-item, .el-sub-menu__title')];
                const el = items.find(e => e.innerText.trim().includes(t));
                if (el) { el.click(); return true; }
                return false;
            }""", text)
            page.wait_for_timeout(1300)
            return ok

        body = page.inner_text("body")
        app_len = len(page.inner_text("#app"))
        print("\n=== 1) 登录态 / 白屏检查 ===")
        print("  #app 文本长度:", app_len)
        print("  顶栏 v0.26.0:", "v0.26.0" in body)
        print("  仍停在登录页(含'登录'按钮):", "登录" in body and "系统帮助" not in body)

        # 客户端配置：标签改名
        click_menu("客户端配置")
        page.wait_for_timeout(800)
        page.screenshot(path=os.path.join(OUTDIR, "验证-客户端配置.png"), full_page=False)
        body2 = page.inner_text("body")
        print("\n=== 2) 标签改名检查 ===")
        print("  出现「升级说明页网址（可选）」:", "升级说明页网址（可选）" in body2)
        print("  旧的「在线更新」仍存在:", "在线更新" in body2)

        # 系统帮助：搜索过滤
        click_menu("系统帮助")
        page.wait_for_timeout(800)
        search = page.locator("input[placeholder*='搜索你遇到的问题']").first
        cnt_before = page.locator(".help-sec .el-collapse-item").count()
        search.fill("考勤")
        page.wait_for_timeout(900)
        cnt_after = page.locator(".help-sec .el-collapse-item").count()
        body3 = page.inner_text("body")
        page.screenshot(path=os.path.join(OUTDIR, "验证-帮助页-搜考勤.png"), full_page=False)
        print("\n=== 3) 帮助搜索过滤检查 ===")
        print("  搜索前 FAQ 条数:", cnt_before)
        print("  搜'考勤'后 FAQ 条数:", cnt_after)
        print("  搜'考勤'后命中含'考勤打卡':", "考勤打卡" in body3)
        # 换一个词
        search.fill("忘记密码")
        page.wait_for_timeout(900)
        cnt2 = page.locator(".help-sec .el-collapse-item").count()
        body4 = page.inner_text("body")
        print("  搜'忘记密码'后 FAQ 条数:", cnt2, " 命中含'管理员密码':", "管理员密码" in body4)
        # 清空恢复
        search.fill("")
        page.wait_for_timeout(600)
        cnt_clear = page.locator(".help-sec .el-collapse-item").count()
        print("  清空后 FAQ 条数(应=全部):", cnt_clear)
        page.screenshot(path=os.path.join(OUTDIR, "验证-帮助页-全量.png"), full_page=False)

        # 错误汇总
        real = [e for e in errors if "PAGEERROR" in e or "CONSOLE[error]" in e]
        print("\n=== 4) 控制台 / 页面错误 ===")
        for e in errors[:30]:
            print("  ", e)
        print("  严重错误(含 pageerror / console.error)数量:", len(real))

        ctx.close()
        browser.close()
        print("\n完成。截图在:", OUTDIR)


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
