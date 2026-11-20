#!/usr/bin/env node
import cluster from 'node:cluster';
import http from 'node:http';
import process from 'node:process';
import { DatabaseSync } from 'node:sqlite';

function parseArgs(argv) {
  const opts = {
    port: Number(process.env.PORT || 3000),
    workers: Number(process.env.WORKERS || 4),
    db: process.env.DBI_BENCH_DB || '',
    rows: Number(process.env.DBI_BENCH_ROWS || 10000),
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' && i + 1 < argv.length) {
      opts.port = Number(argv[++i]);
    } else if (a.startsWith('--port=')) {
      opts.port = Number(a.slice('--port='.length));
    } else if (a === '--workers' && i + 1 < argv.length) {
      opts.workers = Number(argv[++i]);
    } else if (a.startsWith('--workers=')) {
      opts.workers = Number(a.slice('--workers='.length));
    } else if (a === '--db' && i + 1 < argv.length) {
      opts.db = argv[++i];
    } else if (a.startsWith('--db=')) {
      opts.db = a.slice('--db='.length);
    } else if (a === '--rows' && i + 1 < argv.length) {
      opts.rows = Number(argv[++i]);
    } else if (a.startsWith('--rows=')) {
      opts.rows = Number(a.slice('--rows='.length));
    }
  }
  if (!opts.db) {
    console.error('Missing --db or DBI_BENCH_DB');
    process.exit(1);
  }
  if (!Number.isInteger(opts.workers) || opts.workers < 1) {
    opts.workers = 1;
  }
  if (!Number.isInteger(opts.rows) || opts.rows < 1) {
    opts.rows = 10000;
  }
  return opts;
}

const opts = parseArgs(process.argv);

if (opts.workers > 1 && cluster.isPrimary) {
  let shuttingDown = false;

  for (let i = 0; i < opts.workers; i++) {
    cluster.fork();
  }

  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    for (const id of Object.keys(cluster.workers)) {
      const w = cluster.workers[id];
      if (w) w.kill('SIGTERM');
    }
    setTimeout(() => process.exit(0), 2000).unref();
  };

  cluster.on('exit', () => {
    if (shuttingDown && Object.keys(cluster.workers).length === 0) {
      process.exit(0);
    }
  });

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
} else {
  startWorker(opts);
}

function trimTrailingSpaces(s) {
  if (typeof s !== 'string') return s;
  let end = s.length;
  while (end > 0 && s.charCodeAt(end - 1) === 32) {
    end--;
  }
  return end === s.length ? s : s.slice(0, end);
}

function startWorker({ port, db: dbPath, rows: rowCount }) {
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA busy_timeout = 15000');
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA synchronous = NORMAL');
  db.exec('PRAGMA temp_store = MEMORY');
  db.exec('PRAGMA cache_size = -16000');

  const sqliteVersion = db.prepare('SELECT sqlite_version() AS v').get().v;

  const stmtSingle = db.prepare(
    'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id = ?'
  );
  const stmtRange = db.prepare(
    'SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id >= ? AND id < ? ORDER BY id'
  );
  const stmtUpdate = db.prepare(
    'UPDATE items SET counter = counter + 1, updated_at = ? WHERE id = ?'
  );
  const stmtBegin = db.prepare('BEGIN IMMEDIATE');
  const stmtCommit = db.prepare('COMMIT');
  const stmtRollback = db.prepare('ROLLBACK');

  const maxStart = rowCount > 50 ? rowCount - 50 : 1;
  const healthPayload = Buffer.from(
    JSON.stringify({
      status: 'ok',
      mode: 'node',
      node: process.version,
      driver: 'node:sqlite',
      sqlite: sqliteVersion,
    })
  );

  function sendJson(res, status, obj) {
    const body = Buffer.from(JSON.stringify(obj));
    res.writeHead(status, {
      'Content-Type': 'application/json;charset=UTF-8',
      'Content-Length': body.length,
    });
    res.end(body);
  }

  function runUpdateWithRetry(ts, id, attempt, res) {
    try {
      stmtBegin.run();
      stmtUpdate.run(ts, id);
      stmtCommit.run();
      sendJson(res, 200, { id, updated: 1, updated_at: ts });
    } catch (err) {
      try {
        stmtRollback.run();
      } catch {
        // ignore rollback error if transaction was not active
      }
      const msg = String(err && err.message ? err.message : err);
      if (/locked|busy/i.test(msg) && attempt < 20) {
        setTimeout(() => runUpdateWithRetry(ts, id, attempt + 1, res), 2 * attempt);
        return;
      }
      sendJson(res, 500, { error: msg });
    }
  }

  const server = http.createServer((req, res) => {
    const method = req.method;
    const rawUrl = req.url || '/';

    if (method === 'GET') {
      if (rawUrl === '/health') {
        res.writeHead(200, {
          'Content-Type': 'application/json;charset=UTF-8',
          'Content-Length': healthPayload.length,
        });
        res.end(healthPayload);
        return;
      }

      if (rawUrl === '/db/single') {
        const id = Math.floor(Math.random() * rowCount) + 1;
        const row = stmtSingle.get(id);
        if (!row) {
          sendJson(res, 404, { error: 'not found' });
          return;
        }
        sendJson(res, 200, row);
        return;
      }

      if (rawUrl === '/db/queries' || rawUrl.startsWith('/db/queries?')) {
        let n = 20;
        const qIdx = rawUrl.indexOf('?');
        if (qIdx !== -1) {
          const sp = new URLSearchParams(rawUrl.slice(qIdx + 1));
          const rawN = sp.get('n');
          if (rawN !== null) {
            const parsed = Number.parseInt(rawN, 10);
            if (!Number.isNaN(parsed)) n = parsed;
          }
        }
        if (n < 1) n = 1;
        if (n > 500) n = 500;

        const out = new Array(n);
        for (let i = 0; i < n; i++) {
          const id = Math.floor(Math.random() * rowCount) + 1;
          out[i] = stmtSingle.get(id);
        }
        sendJson(res, 200, out);
        return;
      }

      if (rawUrl === '/db/range') {
        const start = Math.floor(Math.random() * maxStart) + 1;
        const end = start + 50;
        const rows = stmtRange.all(start, end);
        for (let i = 0; i < rows.length; i++) {
          const r = rows[i];
          r.code = trimTrailingSpaces(r.code);
          r.category = trimTrailingSpaces(r.category);
          r.notes = trimTrailingSpaces(r.notes);
        }
        sendJson(res, 200, rows);
        return;
      }
    }

    if (method === 'POST' && rawUrl === '/db/update') {
      req.resume();
      req.on('end', () => {
        const id = Math.floor(Math.random() * rowCount) + 1;
        const ts = Math.floor(Date.now() / 1000);
        runUpdateWithRetry(ts, id, 1, res);
      });
      return;
    }

    sendJson(res, 404, { error: 'not found' });
  });

  server.keepAliveTimeout = 60000;
  server.headersTimeout = 65000;
  server.maxRequestsPerSocket = 100000;

  server.listen(port, '127.0.0.1');

  const closeWorker = () => {
    server.close(() => {
      try {
        db.close();
      } catch {
        // ignore
      }
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 1000).unref();
  };

  process.on('SIGTERM', closeWorker);
  process.on('SIGINT', closeWorker);
}
