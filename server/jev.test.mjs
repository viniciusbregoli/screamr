import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { requestBody, summarize, turnsToClassify } from './jev.mjs'
import { start } from './server.mjs'

const rubric = JSON.parse(readFileSync(new URL('./rubric/v1.json', import.meta.url)))
const say = (text, speaker, start) => text.split(' ').map((t, i) => ({ text: t, type: 'word', speaker_id: speaker, start: start + i * 0.4, end: start + i * 0.4 + 0.3 }))

test('only the dominant mic speaker turns of three words or more are classified', () => {
  const mic = [...say('Eu acho que dá para entregar sexta.', 'speaker_0', 0), ...say('Ok.', 'speaker_0', 5), ...say('Someone in the room', 'speaker_1', 9)]
  const turns = turnsToClassify({ mic })
  assert.deepEqual(turns.map((t) => t.text), ['Eu acho que dá para entregar sexta.'])
})

test('a request carries the turn alone, and point_first only for long turns', () => {
  const short = requestBody({ text: 'Vou entregar sexta.', words: 3 }, { rubric, language: 'por' })
  assert.deepEqual(Object.keys(short.questions).sort(), ['commitment', 'could_be_better', 'hedge_function', 'style'])
  assert.deepEqual(Object.keys(short.state), ['turn', 'setting', 'language'])
  assert.equal(short.model, 'jev-1.13.0')
  assert.equal(JSON.stringify(short).includes('"source"'), false) // citations stay in the rubric file
  const long = requestBody({ text: 'x', words: 41 }, { rubric, language: 'por' })
  assert.ok(long.questions.point_first)
})

test('summaries treat assertive as the middle: passive and aggressive both count against it', () => {
  const row = (style, hedge, commitment, cbb) => ({ answers: { style: { choice: style }, hedge_function: { choice: hedge }, commitment: { choice: commitment }, could_be_better: { noul: cbb } } })
  const s = summarize([row('assertive', 'none', 'concrete', 0.1), row('passive', 'softening_hedge', 'vague', 0.9), row('aggressive', 'none', 'none', 0.8), row('not_applicable', 'none', 'none', 0.0)])
  assert.equal(s.positioned_turns, 3)
  assert.equal(s.assertive_share, 0.333)
  assert.equal(s.softening_hedge_share, 0.25)
  assert.equal(s.vague_commitment_share, 0.5)
  assert.equal(s.could_be_better_mean, 0.45)
})

test('baseline meetings are classified in the background, once per words version, never with the call side', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'screamr-sync-'))
  const sent = []
  const fakeJev = async (url, init) => {
    const body = JSON.parse(init.body)
    sent.push(body)
    const answers = Object.fromEntries(Object.entries(body.questions).map(([id, q]) => [id, q.type === 'noul' ? { type: 'noul', noul: 0.2 } : { type: 'choice', choice: Object.keys(q.criteria)[1] }]))
    return new Response(JSON.stringify({ model: body.model, answers, usage: { input_tokens: 900 } }), { status: 200 })
  }
  const s = await start({ dataDir: dir, token: 't', jevKey: 'k', jevFetch: fakeJev })
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
    const manifest = {
      'mic.words.json': await put([...say('Proponho testarmos o modelo esta semana.', 'speaker_0', 0), ...say('Acho que talvez dê.', 'speaker_0', 10)]),
      'system.words.json': await put(say('Segredo do outro lado da chamada.', 'speaker_0', 5)),
      'meta.json': await put({ transcription_mode: 'verbatim', source: 'mac', model_id: 'scribe_v2', languages: { mic: 'por' } }),
    }
    await post([{ kind: 'meeting', id: 'm1', body: JSON.stringify(manifest), updated: 1 }])
    await s.jevIdle()
    assert.equal(sent.length, 2)
    assert.equal(sent.some((b) => b.state.turn.includes('Segredo')), false)
    assert.equal(sent[0].state.language, 'por')

    const jev = await fetch(`${base}/jev`, { headers: auth }).then((r) => r.json())
    assert.equal(jev.rubric_version, 'rubric-v1')
    assert.equal(jev.provisional, true)
    assert.equal(jev.meetings[0].turns.length, 2)
    assert.equal(jev.meetings[0].summary.assertive_share, 1)
    assert.equal(JSON.stringify(jev).includes('Proponho'), false) // no turn text in the response

    // A rename changes names.json but not the words: no new classification.
    await post([{ kind: 'meeting', id: 'm1', body: JSON.stringify({ ...manifest, 'names.json': await put({ 'mic:speaker_0': 'You' }) }), updated: 2 }])
    await s.jevIdle()
    assert.equal(sent.length, 2)

    // An iPhone meeting where the Mac hasn't marked the user's lines is not baseline data: no Jev.
    const iphone = { ...manifest, 'meta.json': await put({ transcription_mode: 'verbatim', source: 'iphone' }) }
    await post([{ kind: 'meeting', id: 'm2', body: JSON.stringify(iphone), updated: 3 }])
    await s.jevIdle()
    assert.equal(sent.length, 2)

    // Once the user's lines are marked (me.json), it counts, and only the marked line is sent.
    await post([{ kind: 'meeting', id: 'm2', body: JSON.stringify({ ...iphone, 'me.json': await put({ spans: [{ channel: 'mic', start: 10, end: 11.5 }] }) }), updated: 4 }])
    await s.jevIdle()
    assert.equal(sent.length, 3)
    assert.equal(sent[2].state.turn, 'Acho que talvez dê.')
  } finally {
    await s.close()
    rmSync(dir, { recursive: true, force: true })
  }
})
