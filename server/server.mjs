// screamr sync server: records (latest edit wins) plus content-addressed blobs.
// No dependencies: Node's built-in HTTP and SQLite. Bodies are opaque JSON strings,
// so new kinds of synced data need no server change.
import { createServer } from 'node:http'
import { DatabaseSync } from 'node:sqlite'
import { createHash, timingSafeEqual } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'

export function start({ dataDir, token, port = 0, host = '127.0.0.1' }) {
  if (!token) throw new Error('SCREAMR_SYNC_TOKEN missing')
  const blobs = join(dataDir, 'blobs')
  const tmp = join(dataDir, 'tmp')
  const snapshots = join(dataDir, 'snapshot')
  for (const d of [blobs, tmp, snapshots]) mkdirSync(d, { recursive: true })

  const db = new DatabaseSync(join(dataDir, 'sync.db'))
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS records (
      kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL,
      updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL,
      PRIMARY KEY (kind, id));
    CREATE INDEX IF NOT EXISTS records_seq ON records (seq);`)
  const changes = db.prepare('SELECT kind, id, body, updated, deleted, seq FROM records WHERE seq > ? ORDER BY seq')
  // A write only lands if it is newer than what the server has; every landed write gets the next seq.
  const upsert = db.prepare(`
    INSERT INTO records (kind, id, body, updated, deleted, seq)
    VALUES (?, ?, ?, ?, ?, (SELECT coalesce(max(seq), 0) + 1 FROM records))
    ON CONFLICT (kind, id) DO UPDATE SET body = excluded.body, updated = excluded.updated,
      deleted = excluded.deleted, seq = excluded.seq
    WHERE excluded.updated > records.updated`)
  const maxSeq = db.prepare('SELECT coalesce(max(seq), 0) AS seq FROM records')

  // restic backs up the data dir nightly; copying a live SQLite file can catch it mid-write,
  // so a consistent copy is kept next to it.
  const snapshot = () => {
    const out = join(snapshots, 'sync.db')
    rmSync(out + '.tmp', { force: true })
    db.exec(`VACUUM INTO '${out}.tmp'`)
    renameSync(out + '.tmp', out)
  }
  snapshot()
  const timer = setInterval(snapshot, 3600_000)

  const expected = Buffer.from(`Bearer ${token}`)
  const authorized = (req) => {
    const got = Buffer.from(req.headers.authorization ?? '')
    return got.length === expected.length && timingSafeEqual(got, expected)
  }
  const send = (res, status, body) => {
    const data = body === undefined ? '' : JSON.stringify(body)
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) })
    res.end(data)
  }
  const readJSON = (req) => new Promise((resolve, reject) => {
    let data = ''
    req.setEncoding('utf8')
    req.on('data', (c) => { data += c })
    req.on('end', () => { try { resolve(JSON.parse(data)) } catch (e) { reject(e) } })
    req.on('error', reject)
  })
  const blobPath = (hash) => join(blobs, hash.slice(0, 2), hash)

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x')
    if (url.pathname === '/healthz') return send(res, 200, { ok: true })
    if (!authorized(req)) return send(res, 401, { error: 'unauthorized' })

    try {
      if (req.method === 'GET' && url.pathname === '/changes') {
        const since = Number(url.searchParams.get('since') ?? 0)
        const records = changes.all(since).map((r) => ({ ...r, deleted: r.deleted === 1 }))
        return send(res, 200, { records, cursor: Number(maxSeq.get().seq) })
      }

      if (req.method === 'POST' && url.pathname === '/records') {
        const records = await readJSON(req)
        if (!Array.isArray(records)) return send(res, 400, { error: 'expected an array' })
        db.exec('BEGIN')
        try {
          for (const r of records) {
            if (typeof r.kind !== 'string' || typeof r.id !== 'string' || typeof r.body !== 'string' || typeof r.updated !== 'number') {
              throw new Error('record needs kind, id, body (string) and updated (number)')
            }
            upsert.run(r.kind, r.id, r.body, r.updated, r.deleted ? 1 : 0)
          }
          db.exec('COMMIT')
        } catch (e) {
          db.exec('ROLLBACK')
          return send(res, 400, { error: e.message })
        }
        return send(res, 200, { cursor: Number(maxSeq.get().seq) })
      }

      const blob = url.pathname.match(/^\/blobs\/([0-9a-f]{64})$/)
      if (blob) {
        const hash = blob[1]
        const path = blobPath(hash)
        if (req.method === 'HEAD') {
          res.writeHead(existsSync(path) ? 200 : 404).end()
          return
        }
        if (req.method === 'GET') {
          if (!existsSync(path)) return send(res, 404, { error: 'no such blob' })
          res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': statSync(path).size })
          createReadStream(path).pipe(res)
          return
        }
        if (req.method === 'PUT') {
          if (existsSync(path)) {
            req.resume()
            return send(res, 200, { stored: false })
          }
          // Written to tmp and renamed only once the content matches its name.
          const part = join(tmp, `${hash}.${process.pid}.${Date.now()}`)
          const digest = createHash('sha256')
          const out = createWriteStream(part)
          req.on('data', (c) => digest.update(c))
          req.pipe(out)
          out.on('finish', () => {
            if (digest.digest('hex') !== hash) {
              rmSync(part, { force: true })
              return send(res, 400, { error: 'content does not match hash' })
            }
            mkdirSync(join(blobs, hash.slice(0, 2)), { recursive: true })
            renameSync(part, path)
            send(res, 201, { stored: true })
          })
          out.on('error', (e) => { rmSync(part, { force: true }); send(res, 500, { error: e.message }) })
          return
        }
      }
      send(res, 404, { error: 'not found' })
    } catch (e) {
      send(res, 500, { error: e.message })
    }
  })

  return new Promise((resolve) => {
    server.listen(port, host, () => resolve({
      port: server.address().port,
      close: () => new Promise((done) => { clearInterval(timer); server.close(() => { db.close(); done() }) }),
    }))
  })
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const s = await start({
    dataDir: process.env.DATA_DIR ?? './data',
    token: process.env.SCREAMR_SYNC_TOKEN,
    port: Number(process.env.PORT ?? 8796),
    host: process.env.HOST ?? '127.0.0.1',
  })
  console.log(`screamr sync listening on ${s.port}`)
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => s.close().then(() => process.exit(0)))
}
