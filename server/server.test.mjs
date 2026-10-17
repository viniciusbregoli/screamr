import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { start } from './server.mjs'

test('records keep the latest edit, blobs are checked against their hash', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const s = await start({ dataDir: dir, token: 't' })
  const base = `http://127.0.0.1:${s.port}`
  const auth = { authorization: 'Bearer t' }
  const post = (records) => fetch(`${base}/records`, { method: 'POST', headers: auth, body: JSON.stringify(records) }).then((r) => r.json())
  try {
    assert.equal((await fetch(`${base}/changes`)).status, 401)
    assert.equal((await fetch(`${base}/changes`, { headers: { authorization: 'Bearer nope' } })).status, 401)

    await post([{ kind: 'meeting', id: 'a', body: '{"v":2}', updated: 2 }])
    await post([{ kind: 'meeting', id: 'a', body: '{"v":1}', updated: 1 }]) // older: ignored
    const { cursor } = await post([{ kind: 'meeting', id: 'b', body: '{}', updated: 5 }])
    const all = await fetch(`${base}/changes?since=0`, { headers: auth }).then((r) => r.json())
    assert.deepEqual(all.records.map((r) => [r.id, r.body]), [['a', '{"v":2}'], ['b', '{}']])
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
