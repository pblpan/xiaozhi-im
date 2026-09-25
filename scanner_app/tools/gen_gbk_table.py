#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""兼容入口：码表生成器已提到仓库根 `tools/gen_gbk_table.py`，两边共用。

这里留一行转发，是为了不打断已经写进文档/回事里的旧调用路径。
"""
import os
import sys

sys.path.insert(0, os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools')))

from gen_gbk_table import main  # noqa: E402

if __name__ == '__main__':
    raise SystemExit(main())
