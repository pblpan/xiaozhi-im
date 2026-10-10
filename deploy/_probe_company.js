const db = require('/app/src/db');
const rows = db.prepare("SELECT key,value FROM settings").all();
for (const r of rows) console.log(' ', r.key, '=', String(r.value).slice(0, 80));
