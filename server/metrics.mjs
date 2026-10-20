// Deterministic speech metrics for one meeting, from Scribe's word timings. No model, no text in the output:
// only counts, rates and durations, so results can leave the server while transcripts stay on it.
export const METRICS_VERSION = 'metrics-v3'

// Same as Transcript.pauseBreak in the app: a longer pause starts a new turn, unless it falls inside a sentence
// (see joinUnfinished). The app's transcript joins those lines the same way (Transcript.joinUnfinished).
const PAUSE_BREAK = 1.0
// Past this, even an unfinished sentence ends the turn: the thought was dropped, not paused.
const MID_SENTENCE_PAUSE = 10
// Scribe closes a sentence with one of these; a turn that stops before one was cut by a pause for thought.
const endsSentence = (text) => /[.!?…]["'”»)\]]*$/u.test(text)

const normalize = (text) => text.toLowerCase().replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '')
const endsAlone = (text) => /[,.!?;:…]$/u.test(text)

/** Consecutive words by one speaker, split at pauses. */
function turns(words) {
  const out = []
  for (const w of words) {
    if (w.type !== 'word' || w.start == null || w.end == null) continue
    const last = out.at(-1)
    if (last && last.speaker === w.speaker_id && w.start - last.end < PAUSE_BREAK) {
      last.words.push(w)
      last.end = w.end
    } else {
      out.push({ speaker: w.speaker_id, start: w.start, end: w.end, words: [w] })
    }
  }
  return out
}

/**
 * Joins the user's turns that a pause cut mid-sentence ("vai ser o-- [1.2 s] qual o trampo que é fazer isso"),
 * as long as nobody else spoke in the gap. Each half alone reads as a fragment and skews its classification.
 */
function joinUnfinished(mine, others) {
  const heard = others.flatMap((t) => t.words)
  const out = []
  for (const t of mine) {
    const last = out.at(-1)
    // Any word of theirs that overlaps the gap, not only one that starts inside it.
    const interrupted = last && heard.some((w) => w.start < t.start && w.end > last.end)
    if (last && !endsSentence(last.words.at(-1).text) && t.start - last.end < MID_SENTENCE_PAUSE && !interrupted) {
      last.words.push(...t.words)
      last.end = t.end
      last.spoken += t.end - t.start
    } else {
      out.push({ ...t, words: [...t.words], spoken: t.end - t.start })
    }
  }
  return out
}

// Speaking time leaves out the pauses joinUnfinished kept inside a turn.
const seconds = (ts) => ts.reduce((s, t) => s + (t.spoken ?? t.end - t.start), 0)

/** Counts each lexicon phrase in a token list, longest phrases first so "não sei se" isn't also "sei". */
function countPhrases(tokens, phrases) {
  const lists = phrases.map((p) => p.split(' ')).sort((a, b) => b.length - a.length)
  const counts = {}
  let total = 0
  for (let i = 0; i < tokens.length; ) {
    const hit = lists.find((p) => p.every((word, k) => tokens[i + k] === word))
    if (hit) {
      const key = hit.join(' ')
      counts[key] = (counts[key] ?? 0) + 1
      total += 1
      i += hit.length
    } else {
      i += 1
    }
  }
  return { total, counts }
}

/** Immediate repetitions of one to three words ("a gente podia, a gente podia"): false starts. */
function repeats(tokens) {
  let count = 0
  for (let i = 0; i < tokens.length; ) {
    const n = [3, 2, 1].find((n) => i + 2 * n <= tokens.length && tokens.slice(i, i + n).join(' ') === tokens.slice(i + n, i + 2 * n).join(' '))
    if (n) {
      count += 1
      i += n
    } else {
      i += 1
    }
  }
  return count
}

/**
 * mic / system: Scribe word lists. meta: the meeting's meta.json, or null for meetings transcribed before it existed.
 * The user's turns are the mic channel's dominant speaker; `mic_speakers` > 1 flags meetings where that's a guess.
 */
/** The user's turns: the mic channel's dominant speaker, by speech time. */
export function myTurns(mic) {
  const micTurns = turns(mic)
  const bySpeaker = new Map()
  for (const t of micTurns) bySpeaker.set(t.speaker, (bySpeaker.get(t.speaker) ?? 0) + (t.end - t.start))
  const me = [...bySpeaker.entries()].sort((a, b) => b[1] - a[1])[0]?.[0]
  return { mine: micTurns.filter((t) => t.speaker === me), rest: micTurns.filter((t) => t.speaker !== me), speakers: bySpeaker.size }
}

/**
 * The user's turns and everyone else's. With me.json (written by the Mac once speakers are assigned, and
 * corrected by hand there) the user is whoever spoke inside its spans, on either channel; that's what lets
 * iPhone meetings, where everyone shares the mic, count. Without it, Mac meetings fall back to the dominant
 * mic speaker.
 */
export function userTurns({ mic = [], system = [], me = null }) {
  const spans = me?.spans ?? []
  const speakers = new Set(mic.filter((w) => w.type === 'word').map((w) => w.speaker_id)).size
  if (!spans.length) {
    const { mine, rest } = myTurns(mic)
    const others = [...rest, ...turns(system)]
    return { mine: joinUnfinished(mine, others), others, speakers, attributed: false }
  }
  const inside = (w, channel) => spans.some((s) => s.channel === channel && w.start >= s.start - 0.01 && w.end <= s.end + 0.01)
  const split = (words, channel) => {
    const timed = words.filter((w) => w.type === 'word' && w.start != null && w.end != null)
    return { mine: timed.filter((w) => inside(w, channel)), rest: timed.filter((w) => !inside(w, channel)) }
  }
  const m = split(mic, 'mic'), s = split(system, 'system')
  const mineWords = [...m.mine, ...s.mine].sort((a, b) => a.start - b.start).map((w) => ({ ...w, speaker_id: 'me' }))
  const others = [...turns(m.rest), ...turns(s.rest)]
  return { mine: joinUnfinished(turns(mineWords), others), others, speakers, attributed: true }
}

export function computeMetrics({ mic = [], system = [], meta = null, me = null, lexicon }) {
  const { mine, others, speakers, attributed } = userTurns({ mic, system, me })

  const words = mine.flatMap((t) => t.words)
  const tokens = words.map((w) => normalize(w.text)).filter(Boolean)
  const wordCount = tokens.length
  const mySeconds = seconds(mine)
  const othersSeconds = seconds(others)
  const per1k = (n) => (wordCount ? (n / wordCount) * 1000 : null)
  const round = (x, digits = 2) => (x == null ? null : Number(x.toFixed(digits)))

  const hedges = countPhrases(tokens, [...lexicon.hedges.pt, ...lexicon.hedges.en])
  const verbatim = meta?.transcription_mode === 'verbatim'
  let fillers = null
  if (verbatim) {
    const always = new Set(lexicon.fillers.always)
    const alone = new Set(lexicon.fillers.only_alone)
    // "é" is a filler in "é." but the verb in "isso é bom": ambiguous words only count when set off by punctuation.
    const count = words.filter((w) => always.has(normalize(w.text)) || (alone.has(normalize(w.text)) && endsAlone(w.text))).length
    const restarts = repeats(tokens)
    fillers = { count, repeats: restarts, per_1k: round(per1k(count + restarts)) }
  }

  return {
    metrics_version: METRICS_VERSION,
    lexicon_version: lexicon.version,
    transcription_mode: meta?.transcription_mode ?? 'unknown',
    source: meta?.source ?? 'unknown',
    model_id: meta?.model_id ?? null,
    language: meta?.languages?.mic ?? null,
    mic_speakers: speakers,
    // Whether the user's turns come from me.json (marked on the Mac) rather than the dominant mic voice.
    attributed,
    // Baseline data: transcribed verbatim, with speech from the user, from a Mac or from an iPhone meeting
    // where the Mac has marked which lines are the user's.
    eligible: verbatim && wordCount > 0 && (meta?.source === 'mac' || attributed),
    my_words: wordCount,
    my_turns: mine.length,
    my_seconds: round(mySeconds, 1),
    others_seconds: round(othersSeconds, 1),
    talk_share: mySeconds + othersSeconds > 0 ? round(mySeconds / (mySeconds + othersSeconds), 3) : null,
    wpm: mySeconds > 0 ? round((wordCount / mySeconds) * 60, 1) : null,
    avg_turn_words: mine.length ? round(wordCount / mine.length, 1) : null,
    avg_turn_seconds: mine.length ? round(mySeconds / mine.length, 1) : null,
    hedges: { count: hedges.total, per_1k: round(per1k(hedges.total)), by_phrase: hedges.counts },
    fillers,
  }
}
