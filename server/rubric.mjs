// The active rubric is the highest-numbered server/rubric/vN.json, so shipping a new version is adding
// one file. Shared by screamr-sync and pdi-lab (imported from SCREAMR_DIR), so both always agree.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const RUBRIC_DIR = fileURLToPath(new URL('./rubric/', import.meta.url))

export function loadRubric(dir = RUBRIC_DIR) {
  // By number, not by name: v10 comes after v9.
  const latest = readdirSync(dir)
    .map((f) => ({ f, n: Number(f.match(/^v(\d+)\.json$/)?.[1]) }))
    .filter((x) => Number.isInteger(x.n))
    .sort((a, b) => b.n - a.n)[0]
  if (!latest) throw new Error(`no rubric vN.json in ${dir}`)
  return JSON.parse(readFileSync(join(dir, latest.f), 'utf8'))
}
