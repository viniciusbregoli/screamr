import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, rmSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { cleanTitle, meetingDate, parseManifest, RETIRED, start, TITLE } from './server.mjs'

test('records keep the latest edit, blobs are checked against their hash', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const s = await start({ dataDir: dir, token: 't' })
  const base = `http://127.0.0.1:${s.port}`
  const auth = { authorization: 'Bearer t' }
  const post = (records) => fetch(`${base}/records`, { method: 'POST', headers: auth, body: JSON.stringify(records) }).then((r) => r.json())
  try {
    assert.equal((await fetch(`${base}/changes`)).status, 401)
    assert.equal((await fetch(`${base}/changes`, { headers: { authorization: 'Bearer nope' } })).status, 401)

    await post([{ kind: 'meeting', id: 'a', body: '{"v":"2"}', updated: 2 }])
    await post([{ kind: 'meeting', id: 'a', body: '{"v":"1"}', updated: 1 }]) // older: ignored
    const { cursor } = await post([{ kind: 'meeting', id: 'b', body: '{}', updated: 5 }])
    const all = await fetch(`${base}/changes?since=0`, { headers: auth }).then((r) => r.json())
    assert.deepEqual(all.records.map((r) => [r.id, r.body]), [['a', '{"v":"2"}'], ['b', '{}']])
    assert.equal(all.cursor, cursor)
    const later = await fetch(`${base}/changes?since=${cursor}`, { headers: auth }).then((r) => r.json())
    assert.equal(later.records.length, 0)

    await post([{ kind: 'meeting', id: 'a', body: '{}', updated: 9, deleted: true }])
    const tomb = await fetch(`${base}/changes?since=${cursor}`, { headers: auth }).then((r) => r.json())
    assert.deepEqual(tomb.records.map((r) => [r.id, r.deleted]), [['a', true]])

    const data = Buffer.from('hello audio')
    const hash = createHash('sha256').update(data).digest('hex')
    assert.equal((await fetch(`${base}/blobs/${hash}`, { method: 'HEAD', headers: auth })).status, 404)
    const wrong = createHash('sha256').update('other').digest('hex')
    assert.equal((await fetch(`${base}/blobs/${wrong}`, { method: 'PUT', headers: auth, body: data })).status, 400)
    assert.equal((await fetch(`${base}/blobs/${hash}`, { method: 'PUT', headers: auth, body: data })).status, 201)
    assert.equal((await fetch(`${base}/blobs/${hash}`, { method: 'HEAD', headers: auth })).status, 200)
    const back = Buffer.from(await (await fetch(`${base}/blobs/${hash}`, { headers: auth })).arrayBuffer())
    assert.deepEqual(back, data)
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('meetings get speech metrics when they sync, and lose them when deleted', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const s = await start({ dataDir: dir, token: 't' })
  const base = `http://127.0.0.1:${s.port}`
  const auth = { authorization: 'Bearer t' }
  const put = async (value) => {
    const data = Buffer.from(JSON.stringify(value))
    const hash = createHash('sha256').update(data).digest('hex')
    await fetch(`${base}/blobs/${hash}`, { method: 'PUT', headers: auth, body: data })
    return hash
  }
  const post = (records) => fetch(`${base}/records`, { method: 'POST', headers: auth, body: JSON.stringify(records) })
  try {
    const words = 'Eu acho que, tipo, dá'.split(' ').map((text, i) => ({ text, type: 'word', speaker_id: 'speaker_0', start: i * 0.4, end: i * 0.4 + 0.3 }))
    const manifest = { 'mic.words.json': await put(words), 'meta.json': await put({ transcription_mode: 'verbatim', source: 'mac', model_id: 'scribe_v2', languages: { mic: 'por' } }) }
    await post([{ kind: 'meeting', id: 'm1', body: JSON.stringify(manifest), updated: 1 }])
    const { metrics } = await fetch(`${base}/metrics`, { headers: auth }).then((r) => r.json())
    assert.equal(metrics.length, 1)
    assert.equal(metrics[0].meeting, 'm1')
    assert.deepEqual(metrics[0].hedges.by_phrase, { acho: 1, tipo: 1 })
    assert.equal(metrics[0].eligible, true)
    assert.equal(JSON.stringify(metrics).includes('dá'), false) // no transcript text leaves the server

    await post([{ kind: 'meeting', id: 'm1', body: '{}', updated: 2, deleted: true }])
    assert.equal((await fetch(`${base}/metrics`, { headers: auth }).then((r) => r.json())).metrics.length, 0)
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('audio is retired after the retention period and unreferenced blobs are collected', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const day = 86_400_000
  let clock = new Date(2026, 9, 17, 12, 0).getTime()
  const open = () => start({ dataDir: dir, token: 't', now: () => clock })
  let s = await open()
  const base = () => `http://127.0.0.1:${s.port}`
  const auth = { authorization: 'Bearer t' }
  const put = async (text) => {
    const data = Buffer.from(text)
    const hash = createHash('sha256').update(data).digest('hex')
    await fetch(`${base()}/blobs/${hash}`, { method: 'PUT', headers: auth, body: data })
    return hash
  }
  const blobFile = (hash) => join(dir, 'blobs', hash.slice(0, 2), hash)
  const age = (hash, days) => utimesSync(blobFile(hash), new Date(clock - days * day), new Date(clock - days * day))
  try {
    const oldAudio = await put('old audio'), oldWords = await put('[]'), newAudio = await put('new audio')
    const orphan = await put('superseded transcript'), fresh = await put('uploaded, record not posted yet')
    await fetch(`${base()}/records`, { method: 'POST', headers: auth, body: JSON.stringify([
      // Other kinds of record carry no file manifest and must not stop the collection.
      { kind: 'setting', id: 'theme', body: 'neon', updated: 1 },
      { kind: 'meeting', id: '2026-10-17 09.00.00', body: JSON.stringify({ 'mic.m4a': oldAudio, 'mic.words.json': oldWords }), updated: 1 },
      { kind: 'meeting', id: '2027-01-14 09.00.00', body: JSON.stringify({ 'mic.m4a': newAudio }), updated: 1 },
    ]) })
    for (const h of [oldAudio, oldWords, newAudio, orphan]) age(h, 2)

    // 91 days after the first meeting: its audio retires, the second meeting's (1 day old) doesn't.
    await s.close()
    clock += 91 * day
    for (const h of [oldAudio, oldWords, newAudio, orphan]) age(h, 2)
    age(fresh, 0)
    s = await open()
    const { records } = await fetch(`${base()}/changes?since=0`, { headers: auth }).then((r) => r.json())
    const body = (id) => JSON.parse(records.find((r) => r.id === id).body)
    assert.deepEqual(body('2026-10-17 09.00.00'), { 'mic.m4a': RETIRED, 'mic.words.json': oldWords })
    assert.deepEqual(body('2027-01-14 09.00.00'), { 'mic.m4a': newAudio })
    assert.ok(records.find((r) => r.id === '2026-10-17 09.00.00').updated > 1) // newer than any device's version

    assert.equal(existsSync(blobFile(oldAudio)), false) // retired, no longer referenced
    assert.equal(existsSync(blobFile(orphan)), false) // superseded, nobody references it
    assert.equal(existsSync(blobFile(oldWords)), true) // transcripts stay
    assert.equal(existsSync(blobFile(newAudio)), true)
    assert.equal(existsSync(blobFile(fresh)), true) // too young: its record may still be on the way
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('meeting dates come from the folder name, with or without seconds', () => {
  assert.equal(meetingDate('2026-10-17 09.30.15'), new Date(2026, 9, 17, 9, 30, 15).getTime())
  assert.equal(meetingDate('2026-10-17 09.30'), new Date(2026, 9, 17, 9, 30).getTime())
  assert.equal(meetingDate('not a meeting'), null)
})

test('a meeting record must be a file manifest, so retention can always read it', async () => {
  assert.deepEqual(parseManifest('{"mic.m4a":"abc","system.m4a":"retired"}'), { 'mic.m4a': 'abc', 'system.m4a': 'retired' })
  for (const bad of ['not json', '[]', 'null', '{"mic.m4a":1}']) assert.equal(parseManifest(bad), null)
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const s = await start({ dataDir: dir, token: 't' })
  try {
    const post = (records) => fetch(`http://127.0.0.1:${s.port}/records`, { method: 'POST', headers: { authorization: 'Bearer t' }, body: JSON.stringify(records) })
    assert.equal((await post([{ kind: 'meeting', id: 'x', body: 'not json', updated: 1 }])).status, 400)
    assert.equal((await post([{ kind: 'meeting', id: 'x', body: '{}', updated: 2, deleted: true }])).status, 200) // tombstones carry no manifest
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a meeting title is stored as title.txt in a new version of its record', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const s = await start({ dataDir: dir, token: 't' })
  const base = `http://127.0.0.1:${s.port}`
  const auth = { authorization: 'Bearer t' }
  const rename = (id, body, headers = auth) => fetch(`${base}/meetings/${encodeURIComponent(id)}/title`, { method: 'PUT', headers, body: JSON.stringify(body) })
  const record = async (id) => (await fetch(`${base}/changes?since=0`, { headers: auth }).then((r) => r.json())).records.find((r) => r.id === id)
  const blob = async (hash) => (await fetch(`${base}/blobs/${hash}`, { headers: auth })).text()
  const id = '2026-10-16 14.00.00'
  try {
    const words = Buffer.from(JSON.stringify('Vou entregar sexta'.split(' ').map((text, i) => ({ text, type: 'word', speaker_id: 'speaker_0', start: i, end: i + 0.5 }))))
    const wordsHash = createHash('sha256').update(words).digest('hex')
    await fetch(`${base}/blobs/${wordsHash}`, { method: 'PUT', headers: auth, body: words })
    await fetch(`${base}/records`, { method: 'POST', headers: auth, body: JSON.stringify([{ kind: 'meeting', id, body: JSON.stringify({ 'mic.m4a': 'aa', 'mic.words.json': wordsHash }), updated: 1 }]) })
    const before = await record(id)

    assert.equal((await rename(id, { title: 'x' }, {})).status, 401)
    assert.equal((await rename('nope', { title: 'x' })).status, 404)
    assert.equal((await rename(id, { title: 3 })).status, 400)
    assert.equal((await rename(id, { title: 'x'.repeat(121) })).status, 400)

    const ok = await rename(id, { title: '  Planejamento\nsprint 42  ' })
    assert.deepEqual(await ok.json(), { ok: true, title: 'Planejamento sprint 42' })
    const after = await record(id)
    assert.ok(after.seq > before.seq, 'devices see it as a change')
    const manifest = JSON.parse(after.body)
    assert.equal(manifest['mic.m4a'], 'aa', 'other files untouched')
    assert.equal(await blob(manifest[TITLE]), 'Planejamento sprint 42')
    const metrics = await fetch(`${base}/metrics`, { headers: auth }).then((r) => r.json())
    assert.equal(metrics.metrics.find((m) => m.meeting === id).title, 'Planejamento sprint 42')

    // Clearing keeps the entry with an empty file: devices never drop a file the manifest stops listing.
    await rename(id, { title: '' })
    const cleared = JSON.parse((await record(id)).body)
    assert.equal(await blob(cleared[TITLE]), '')
    const untitled = await fetch(`${base}/metrics`, { headers: auth }).then((r) => r.json())
    assert.equal(untitled.metrics.find((m) => m.meeting === id).title, null)

    await fetch(`${base}/records`, { method: 'POST', headers: auth, body: JSON.stringify([{ kind: 'meeting', id, body: '{}', updated: 99999999999, deleted: true }]) })
    assert.equal((await rename(id, { title: 'x' })).status, 404)
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('titles are one line, trimmed and at most 120 characters', () => {
  assert.equal(cleanTitle('  a\r\nb  '), 'a b')
  assert.equal(cleanTitle('é'.repeat(120)), 'é'.repeat(120))
  assert.equal(cleanTitle('é'.repeat(121)), null)
})
