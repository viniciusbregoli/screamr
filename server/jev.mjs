// Classifies the user's meeting turns with Jev (TypeSafe System One) against a versioned rubric.
// Only the user's own turns leave the server: never the other side of the call.
import { userTurns } from './metrics.mjs'

const ENDPOINT = 'https://api.typesafe.ai/v1/systemone'
// Turns this short ("Sim.", "Ok, beleza.") carry no position worth classifying.
const MIN_WORDS = 3

/** The user's turns worth classifying, with their text and position in the meeting. */
export function turnsToClassify({ mic = [], system = [], me = null }) {
  return userTurns({ mic, system, me }).mine
    .map((t, index) => ({ index, start: t.start, end: t.end, words: t.words.length, text: t.words.map((w) => w.text).join(' ') }))
    .filter((t) => t.words >= MIN_WORDS)
}

/** All of a turn's questions go in one request: they run in parallel on the same state. */
export function requestBody(turn, { rubric, language }) {
  const questions = Object.fromEntries(
    Object.entries(rubric.questions)
      .filter(([id]) => id !== 'point_first' || turn.words > rubric.long_turn_words)
      .map(([id, { source, ...question }]) => [id, question]),
  )
  return { model: rubric.model, state: { turn: turn.text, setting: rubric.setting, language: language ?? 'unknown' }, questions }
}

export async function classify(turn, { rubric, language, apiKey, fetchImpl = fetch }) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const r = await fetchImpl(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(requestBody(turn, { rubric, language })),
    })
    if (r.status === 429 || r.status === 529) {
      await new Promise((done) => setTimeout(done, 1000 * 2 ** attempt))
      continue
    }
    if (!r.ok) throw new Error(`Jev HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    const body = await r.json()
    return { model_id: body.model, answers: body.answers, input_tokens: body.usage?.input_tokens ?? 0 }
  }
  throw new Error('Jev rate limited')
}

/**
 * One meeting's picture, combined in code so weights and thresholds can change without re-running inference.
 * Assertive is the middle of the scale: passive and aggressive both count against the turn.
 */
export function summarize(rows) {
  const positioned = rows.filter((r) => r.answers.style?.choice && r.answers.style.choice !== 'not_applicable')
  const share = (list, pred) => (list.length ? Number((list.filter(pred).length / list.length).toFixed(3)) : null)
  const mean = (xs) => (xs.length ? Number((xs.reduce((a, b) => a + b, 0) / xs.length).toFixed(3)) : null)
  const hedged = rows.filter((r) => r.answers.hedge_function?.choice && r.answers.hedge_function.choice !== 'none')
  const committed = rows.filter((r) => ['concrete', 'vague'].includes(r.answers.commitment?.choice))
  const long = rows.filter((r) => r.answers.point_first)
  return {
    turns: rows.length,
    positioned_turns: positioned.length,
    assertive_share: share(positioned, (r) => r.answers.style.choice === 'assertive'),
    passive_share: share(positioned, (r) => r.answers.style.choice === 'passive'),
    aggressive_share: share(positioned, (r) => r.answers.style.choice === 'aggressive'),
    softening_hedge_share: share(rows, (r) => r.answers.hedge_function?.choice === 'softening_hedge'),
    softening_of_hedged: share(hedged, (r) => r.answers.hedge_function.choice === 'softening_hedge'),
    vague_commitment_share: share(committed, (r) => r.answers.commitment.choice === 'vague'),
    could_be_better_mean: mean(rows.map((r) => r.answers.could_be_better?.noul).filter((x) => x != null)),
    point_first_mean: mean(long.map((r) => r.answers.point_first.noul)),
  }
}
