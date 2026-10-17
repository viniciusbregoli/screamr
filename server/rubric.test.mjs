import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadRubric } from './rubric.mjs'

test('the highest-numbered rubric file is active, compared as numbers', () => {
  const dir = mkdtempSync(join(tmpdir(), 'rubric-'))
  try {
    for (const n of [1, 2, 10]) writeFileSync(join(dir, `v${n}.json`), JSON.stringify({ version: `rubric-v${n}` }))
    writeFileSync(join(dir, 'v11-draft.json'), JSON.stringify({ version: 'draft' })) // not vN.json: ignored
    assert.equal(loadRubric(dir).version, 'rubric-v10')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the shipped rubric loads', () => {
  assert.match(loadRubric().version, /^rubric-v\d+$/)
})
