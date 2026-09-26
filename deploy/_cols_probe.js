'use strict';
/**
 * 线上"表里到底有没有这一列"的最小探针（跑在容器里）。
 *
 * 🔴 为什么需要它：飞牛这台机器**没有 sqlite3 命令**，而热更脚本原来用
 *    `sqlite3 ... PRAGMA table_info` 验列 —— 结果永远报"缺列"，
 *    看着像迁移没跑，其实是压根没跑成那条命令。
 *
 * 用法（宿主机，传进去再执行，别用命令行内联，转义层数会爆）：
 *   put_file(deploy/_cols_probe.js, '/vol1/@appcenter/xiaozhi-im/src/_cols_probe.js')
 *   docker exec xiaozhi-im node /app/_cols_probe.js <库文件路径>
 *
 * ⚠️ 库文件路径要从 `docker inspect --format '{{json .HostConfig.Binds}}'`
 *    （容器内 DATA_DIR=/data 对应的宿主机侧）问出来，别按想象写。
 */
const { DatabaseSync } = require('node:sqlite');

// 参数格式：`<库文件路径> [表名=期望列1,期望列2 ...]`
//   例：node _cols_probe.js /data/xiaozhi-im.db tr_lesson=link_url tr_progress=watched_sec
//   不传"期望列"就只打印所有表的列。
const dbPath = process.argv[2];
const specs = process.argv.slice(3)
  .map((a) => a.split('='))
  .map(([t, cols]) => [t, (cols || '').split(',').filter(Boolean)]);
if (!dbPath) {
  console.error('用法: node _cols_probe.js <库文件路径> [表名=期望列,期望列 ...]');
  process.exit(2);
}

const db = new DatabaseSync(dbPath);
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r) => r.name);

for (const t of tables) {
  const cols = db.prepare(`PRAGMA table_info(${t})`).all().map((c) => c.name);
  const spec = specs.find(([n]) => n === t);
  if (!spec) continue;
  const [, want] = spec;
  const miss = want.filter((w) => !cols.includes(w));
  console.log(`${t}: ${cols.join(',')}${miss.length ? '   → 缺: ' + miss.join(',') : '   ✓ 齐'}`);
}
db.close();
