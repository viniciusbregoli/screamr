import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { computeMetrics } from './metrics.mjs'

const lexicon = JSON.parse(readFileSync(new URL('./lexicon/v1.json', import.meta.url)))
const meta = { transcription_mode: 'verbatim', source: 'mac', model_id: 'scribe_v2', languages: { mic: 'por' } }

// One word every 0.4 s starting at `start`, the way Scribe times them.
const say = (text, speaker, start) => text.split(' ').map((t, i) => ({ text: t, type: 'word', speaker_id: speaker, start: start + i * 0.4, end: start + i * 0.4 + 0.3 }))

test('counts hedges, fillers and false starts in the user turns only', () => {
  const mic = say('Hum, é. Então, eu acho que, tipo, a gente podia, a gente podia testar, né? Isso é bom.', 'speaker_0', 0)
  const system = say('Não sei se acho isso.', 'speaker_0', 20) // the other side's hedges never count
  const m = computeMetrics({ mic, system, meta, lexicon })
  assert.equal(m.my_words, 18)
  assert.deepEqual(m.hedges.by_phrase, { acho: 1, tipo: 1 })
  assert.equal(m.fillers.count, 2) // "Hum," and "é." but not the verb in "Isso é bom."
  assert.equal(m.fillers.repeats, 1) // "a gente podia, a gente podia"
  assert.equal(m.eligible, true)
  assert.equal(m.talk_share, 0.789) // 7.1 s of the user vs 1.9 s of the call
})

test('multi-word hedges win over the words inside them', () => {
  const m = computeMetrics({ mic: say('Não sei se dá, I think maybe we could, kind of', 'speaker_0', 0), meta, lexicon })
  assert.deepEqual(m.hedges.by_phrase, { 'não sei se': 1, 'i think': 1, maybe: 1, 'kind of': 1 })
})

test('the dominant mic speaker is the user, and turns split at pauses', () => {
  const mic = [...say('one two three four five', 'speaker_0', 0), ...say('six seven', 'speaker_0', 5), ...say('someone else', 'speaker_1', 10)]
  const m = computeMetrics({ mic, meta, lexicon })
  assert.equal(m.mic_speakers, 2)
  assert.equal(m.my_turns, 2)
  assert.equal(m.my_words, 7)
  assert.equal(m.avg_turn_words, 3.5)
})

test('fillers only count in verbatim meetings, and only Mac verbatim meetings are baseline data', () => {
  const mic = say('Hum, vamos fazer.', 'speaker_0', 0)
  const clean = computeMetrics({ mic, meta: { ...meta, transcription_mode: 'clean' }, lexicon })
  assert.equal(clean.fillers, null)
  assert.equal(clean.eligible, false)
  assert.equal(computeMetrics({ mic, meta: { ...meta, source: 'iphone' }, lexicon }).eligible, false)
  assert.equal(computeMetrics({ mic, meta: null, lexicon }).transcription_mode, 'unknown')
})
