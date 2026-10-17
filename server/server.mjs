// screamr sync server: records (latest edit wins) plus content-addressed blobs.
// No dependencies: Node's built-in HTTP and SQLite. Bodies are opaque JSON strings,
// so new kinds of synced data need no server change.
import { createServer } from 'node:http'
import { DatabaseSync } from 'node:sqlite'
import { createHash, timingSafeEqual } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { computeMetrics, METRICS_VERSION } from './metrics.mjs'
import { classify, summarize, turnsToClassify } from './jev.mjs'
import { loadRubric } from './rubric.mjs'

export const RETIRED = 'retired'
const AUDIO = ['mic.m4a', 'system.m4a']

/** A meeting's files, `{ name: sha256 | "retired" }`, or null when the body isn't one. */
export function parseManifest(body) {
  try {
    const m = JSON.parse(body)
    return m && typeof m === 'object' && !Array.isArray(m) && Object.values(m).every((v) => typeof v === 'string') ? m : null
  } catch {
    return null
  }
}

/** A meeting's recording time from its folder name, "yyyy-MM-dd HH.mm.ss" (older ones without seconds), in local time. */
export function meetingDate(id) {
  const m = id.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2})\.(\d{2})(?:\.(\d{2}))?$/)
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)).getTime() : null
}

const defaultLexicon = () => JSON.parse(readFileSync(new URL('./lexicon/v1.json', import.meta.url)))

export function start({ dataDir, token, port = 0, host = '127.0.0.1', lexicon = defaultLexicon(), rubric = loadRubric(), jevKey = process.env.TYPESAFE_API_KEY, jevFetch = fetch, retentionDays = 90, now = Date.now }) {
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
    CREATE INDEX IF NOT EXISTS records_seq ON records (seq);
    CREATE TABLE IF NOT EXISTS metrics (meeting TEXT PRIMARY KEY, version TEXT NOT NULL, body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS jev (
      meeting TEXT NOT NULL, turn INTEGER NOT NULL, rubric_version TEXT NOT NULL, model_id TEXT NOT NULL,
      start REAL, end REAL, words INTEGER, answers TEXT NOT NULL, input_tokens INTEGER, classified_at TEXT,
      PRIMARY KEY (meeting, turn, rubric_version));
    CREATE TABLE IF NOT EXISTS jev_meetings (
      meeting TEXT NOT NULL, rubric_version TEXT NOT NULL, words_hash TEXT NOT NULL, done_at TEXT, error TEXT,
      PRIMARY KEY (meeting, rubric_version));`)
  const changes = db.prepare('SELECT kind, id, body, updated, deleted, seq FROM records WHERE seq > ? ORDER BY seq')
  // A write only lands if it is newer than what the server has; every landed write gets the next seq.
  const upsert = db.prepare(`
    INSERT INTO records (kind, id, body, updated, deleted, seq)
    VALUES (?, ?, ?, ?, ?, (SELECT coalesce(max(seq), 0) + 1 FROM records))
    ON CONFLICT (kind, id) DO UPDATE SET body = excluded.body, updated = excluded.updated,
      deleted = excluded.deleted, seq = excluded.seq
    WHERE excluded.updated > records.updated`)
  const maxSeq = db.prepare('SELECT coalesce(max(seq), 0) AS seq FROM records')

  // Speech metrics per meeting, recomputed when its files change or the metric or word-list version does.
  const metricsVersion = `${METRICS_VERSION}+${lexicon.version}`
  const meetingRecord = db.prepare("SELECT body, deleted FROM records WHERE kind = 'meeting' AND id = ?")
  const saveMetrics = db.prepare('INSERT INTO metrics (meeting, version, body) VALUES (?, ?, ?) ON CONFLICT (meeting) DO UPDATE SET version = excluded.version, body = excluded.body')
  const dropMetrics = db.prepare('DELETE FROM metrics WHERE meeting = ?')
  const allMetrics = db.prepare('SELECT meeting, body FROM metrics ORDER BY meeting')

  // Jev classification of the user's turns, in the background so sync never waits on it. A meeting is
  // re-classified only when its mic words change (not on a rename) or the rubric version does.
  const jevState = db.prepare('SELECT words_hash, done_at FROM jev_meetings WHERE meeting = ? AND rubric_version = ?')
  const markJev = db.prepare('INSERT INTO jev_meetings (meeting, rubric_version, words_hash, done_at, error) VALUES (?, ?, ?, ?, ?) ON CONFLICT (meeting, rubric_version) DO UPDATE SET words_hash = excluded.words_hash, done_at = excluded.done_at, error = excluded.error')
  const saveJev = db.prepare('INSERT INTO jev (meeting, turn, rubric_version, model_id, start, end, words, answers, input_tokens, classified_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (meeting, turn, rubric_version) DO UPDATE SET model_id = excluded.model_id, start = excluded.start, end = excluded.end, words = excluded.words, answers = excluded.answers, input_tokens = excluded.input_tokens, classified_at = excluded.classified_at')
  const clearJev = db.prepare('DELETE FROM jev WHERE meeting = ? AND rubric_version = ?')
  const dropJev = db.prepare('DELETE FROM jev WHERE meeting = ?')
  const dropJevMeeting = db.prepare('DELETE FROM jev_meetings WHERE meeting = ?')
  const jevRows = db.prepare('SELECT meeting, turn, model_id, start, end, words, answers FROM jev WHERE rubric_version = ? ORDER BY meeting, turn')
  const jevQueue = new Map()
  let jevDrain = Promise.resolve()
  const queueJev = (id, wordsHash, words, language) => {
    if (!jevKey) return
    const state = jevState.get(id, rubric.version)
    if (state?.words_hash === wordsHash && state.done_at) return
    const idle = jevQueue.size === 0
    jevQueue.set(id, { wordsHash, words, language })
    if (idle) jevDrain = drainJev()
  }
  const drainJev = async () => {
    while (jevQueue.size) {
      const [id, job] = jevQueue.entries().next().value
      jevQueue.delete(id)
      try {
        const turns = turnsToClassify(job.words)
        const results = []
        // A few turns at a time: fast for a long meeting without tripping the rate limit.
        for (let i = 0; i < turns.length; i += 4) {
          results.push(...await Promise.all(turns.slice(i, i + 4).map(async (t) => ({ t, r: await classify(t, { rubric, language: job.language, apiKey: jevKey, fetchImpl: jevFetch }) }))))
        }
        const now = new Date().toISOString()
        db.exec('BEGIN')
        clearJev.run(id, rubric.version)
        for (const { t, r } of results) saveJev.run(id, t.index, rubric.version, r.model_id, t.start, t.end, t.words, JSON.stringify(r.answers), r.input_tokens, now)
        markJev.run(id, rubric.version, job.wordsHash, now, null)
        db.exec('COMMIT')
      } catch (e) {
        if (db.isTransaction) db.exec('ROLLBACK')
        markJev.run(id, rubric.version, job.wordsHash, null, e.message)
        console.error(`jev for ${id} failed: ${e.message}`)
      }
    }
  }
  // What Jev's answers depend on: the words, and which of them are the user's.
  const wordsKey = (manifest) => ['mic.words.json', 'system.words.json', 'me.json'].map((f) => manifest[f] ?? '').join(':')
  const readBlob = (manifest, name) => {
    const hash = manifest[name]
    if (!hash || !existsSync(blobPath(hash))) return undefined
    return JSON.parse(readFileSync(blobPath(hash), 'utf8'))
  }
  const updateMetrics = (id) => {
    try {
      const record = meetingRecord.get(id)
      const manifest = record && !record.deleted ? JSON.parse(record.body) : {}
      const mic = readBlob(manifest, 'mic.words.json')
      if (!mic) {
        dropMetrics.run(id)
        dropJev.run(id)
        dropJevMeeting.run(id)
        return
      }
      const meta = readBlob(manifest, 'meta.json') ?? null
      const system = readBlob(manifest, 'system.words.json') ?? []
      const me = readBlob(manifest, 'me.json') ?? null
      const metrics = computeMetrics({ mic, system, meta, me, lexicon })
      saveMetrics.run(id, metricsVersion, JSON.stringify({ ...metrics, computed_at: new Date().toISOString() }))
      if (metrics.eligible) queueJev(id, wordsKey(manifest), { mic, system, me }, metrics.language)
    } catch (e) {
      // Metrics are derived data: a bad file must never break sync.
      console.error(`metrics for ${id} failed: ${e.message}`)
    }
  }

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

  // Meeting audio carries everyone's voices, biometric data under LGPD, so it's kept for retentionDays from the
  // recording date and then retired: the server writes RETIRED in place of the hash, which devices treat as final
  // (they delete their copy and never re-upload it). The server writes it because it's always on and knows every
  // meeting's date, while devices can be offline for months. Transcripts stay.
  const liveRecords = db.prepare('SELECT kind, id, body, updated FROM records WHERE deleted = 0')
  const retireAudio = () => {
    const cutoff = now() - retentionDays * 86_400_000
    for (const r of liveRecords.all()) {
      if (r.kind !== 'meeting') continue
      const recorded = meetingDate(r.id)
      if (recorded == null || recorded > cutoff) continue
      const manifest = parseManifest(r.body)
      if (!manifest) {
        console.error(`retention skipped ${r.id}: its record is not a file manifest`)
        continue
      }
      const audio = AUDIO.filter((f) => manifest[f] && manifest[f] !== RETIRED)
      if (!audio.length) continue
      for (const f of audio) manifest[f] = RETIRED
      upsert.run('meeting', r.id, JSON.stringify(manifest), Math.max(now() / 1000, r.updated + 0.001), 0)
    }
  }
  // Then deletes blobs no live record references: retired audio, deleted meetings, superseded versions.
  // Only blobs older than a day, since devices upload a meeting's files before posting its record.
  const collectGarbage = () => {
    const referenced = new Set()
    for (const r of liveRecords.all()) {
      const manifest = parseManifest(r.body)
      // A record we can't read might reference anything, so collect nothing rather than guess.
      if (!manifest) return console.error(`garbage collection skipped: record ${r.id} is not a file manifest`)
      for (const v of Object.values(manifest)) referenced.add(v)
    }
    // An empty or broken database must never read as "nothing is referenced".
    if (!referenced.size) return
    const youngest = now() - 86_400_000
    for (const dir of readdirSync(blobs)) {
      for (const hash of readdirSync(join(blobs, dir))) {
        const path = join(blobs, dir, hash)
        if (!referenced.has(hash) && statSync(path).mtimeMs < youngest) rmSync(path, { force: true })
      }
    }
  }
  const retention = () => {
    try {
      retireAudio()
      collectGarbage()
    } catch (e) {
      console.error(`retention failed: ${e.message}`)
    }
  }
  retention()
  const retentionTimer = setInterval(retention, 86_400_000)

  // Catch up on meetings synced before this metric or word-list version.
  const stale = db.prepare("SELECT r.id FROM records r LEFT JOIN metrics m ON m.meeting = r.id WHERE r.kind = 'meeting' AND r.deleted = 0 AND (m.version IS NULL OR m.version != ?)")
  for (const { id } of stale.all(metricsVersion)) updateMetrics(id)
  // And on baseline meetings not yet classified under this rubric (new rubric version, earlier failures).
  for (const { meeting, body } of allMetrics.all()) {
    const metrics = JSON.parse(body)
    if (!metrics.eligible) continue
    const record = meetingRecord.get(meeting)
    const manifest = record && !record.deleted ? JSON.parse(record.body) : {}
    const mic = readBlob(manifest, 'mic.words.json')
    if (mic) queueJev(meeting, wordsKey(manifest), { mic, system: readBlob(manifest, 'system.words.json') ?? [], me: readBlob(manifest, 'me.json') ?? null }, metrics.language)
  }

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

      if (req.method === 'GET' && url.pathname === '/jev') {
        // Answers and timings only: the turn text stays in the meeting's files.
        const byMeeting = new Map()
        for (const row of jevRows.all(rubric.version)) {
          const turn = { turn: row.turn, start: row.start, end: row.end, words: row.words, model_id: row.model_id, answers: JSON.parse(row.answers) }
          byMeeting.set(row.meeting, [...(byMeeting.get(row.meeting) ?? []), turn])
        }
        const meetings = [...byMeeting].map(([meeting, turns]) => ({ meeting, summary: summarize(turns), turns }))
        return send(res, 200, { rubric_version: rubric.version, provisional: rubric.provisional ?? false, model: rubric.model, meetings })
      }

      if (req.method === 'GET' && url.pathname === '/metrics') {
        return send(res, 200, { metrics: allMetrics.all().map((r) => ({ meeting: r.meeting, ...JSON.parse(r.body) })) })
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
            // Retention and garbage collection read every meeting's manifest, so a broken one is refused here.
            if (r.kind === 'meeting' && !r.deleted && !parseManifest(r.body)) {
              throw new Error(`meeting ${r.id}: body must be a JSON object of file names to hashes`)
            }
            upsert.run(r.kind, r.id, r.body, r.updated, r.deleted ? 1 : 0)
          }
          db.exec('COMMIT')
        } catch (e) {
          db.exec('ROLLBACK')
          return send(res, 400, { error: e.message })
        }
        // Clients upload a meeting's files before its record, so they're all here by now.
        for (const r of records) if (r.kind === 'meeting') updateMetrics(r.id)
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
      /** Resolves once queued Jev classifications finish (tests and graceful shutdown). */
      jevIdle: () => jevDrain,
      close: () => new Promise((done) => { clearInterval(timer); clearInterval(retentionTimer); server.close(() => jevDrain.finally(() => { db.close(); done() })) }),
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
