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
  const mic = [...say('one two three four five.', 'speaker_0', 0), ...say('six seven', 'speaker_0', 5), ...say('someone else', 'speaker_1', 10)]
  const m = computeMetrics({ mic, meta, lexicon })
  assert.equal(m.mic_speakers, 2)
  assert.equal(m.my_turns, 2)
  assert.equal(m.my_words, 7)
  assert.equal(m.avg_turn_words, 3.5)
})

test('a pause inside a sentence does not split the turn, unless someone spoke or the pause ran long', () => {
  const first = say('vou avaliar qual que vai ser o--', 'speaker_0', 0) // ends at 2.7 s, unfinished
  const turnsWith = (second, system = []) => computeMetrics({ mic: [...first, ...second], system, meta, lexicon }).my_turns
  assert.equal(turnsWith(say('qual o trampo que é fazer isso.', 'speaker_0', 3.9)), 1)
  assert.equal(turnsWith(say('qual o trampo que é fazer isso.', 'speaker_0', 3.9), say('Uhum.', 'speaker_0', 3.1)), 2)
  // A word of theirs that starts before the gap and runs into it also counts as speaking in between.
  const overlapping = [{ text: 'Uhum.', type: 'word', speaker_id: 'speaker_0', start: 2.5, end: 3.2 }]
  assert.equal(turnsWith(say('qual o trampo que é fazer isso.', 'speaker_0', 3.9), overlapping), 2)
  // The joined pause is not speaking time: two 2.7 s halves count 5.4 s, not the 6.6 s from first word to last.
  const joined = computeMetrics({ mic: [...first, ...say('qual o trampo que é fazer isso.', 'speaker_0', 3.9)], meta, lexicon })
  assert.equal(joined.my_seconds, 5.4)
  assert.equal(turnsWith(say('qual o trampo que é fazer isso.', 'speaker_0', 14)), 2)
  const finished = say('vou avaliar isso.', 'speaker_0', 0)
  assert.equal(computeMetrics({ mic: [...finished, ...say('Depois eu volto.', 'speaker_0', 2.5)], meta, lexicon }).my_turns, 2)
})

test('fillers only count in verbatim meetings, and only Mac verbatim meetings are baseline data', () => {
  const mic = say('Hum, vamos fazer.', 'speaker_0', 0)
  const clean = computeMetrics({ mic, meta: { ...meta, transcription_mode: 'clean' }, lexicon })
  assert.equal(clean.fillers, null)
  assert.equal(clean.eligible, false)
  assert.equal(computeMetrics({ mic, meta: { ...meta, source: 'iphone' }, lexicon }).eligible, false)
  assert.equal(computeMetrics({ mic, meta: null, lexicon }).transcription_mode, 'unknown')
})

test('marked lines decide who the user is, on either channel, and make iPhone meetings count', () => {
  // iPhone: everyone on the mic. Scribe called both people speaker_0; the Mac marked only the second line as the user's.
  const mic = [...say('Bom dia, tudo bem?', 'speaker_0', 0), ...say('Eu acho que dá para entregar sexta.', 'speaker_0', 5)]
  const iphone = { ...meta, source: 'iphone' }
  const unmarked = computeMetrics({ mic, meta: iphone, lexicon })
  assert.equal(unmarked.eligible, false)
  assert.equal(unmarked.attributed, false)
  const marked = computeMetrics({ mic, meta: iphone, me: { spans: [{ channel: 'mic', start: 5, end: 7.8 }] }, lexicon })
  assert.equal(marked.attributed, true)
  assert.equal(marked.eligible, true)
  assert.equal(marked.my_words, 7)
  assert.deepEqual(marked.hedges.by_phrase, { acho: 1 })
  assert.equal(marked.others_seconds, 1.5)
})
