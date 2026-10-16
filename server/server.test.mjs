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
