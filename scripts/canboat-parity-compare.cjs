#!/usr/bin/env node
// Dev tool — not used by any workflow or by the image at runtime.
//
// Runs INSIDE the image (driven by canboat-parity.sh): decodes the canboatjs
// test corpus through both N2K decode paths the image ships —
//   1. canboat's C `analyzer -json -si -camel` (the native pipeline
//      signalk-server spawns for non-canboatjs connection types)
//   2. the image's own @canboat/canboatjs FromPgn (the default pipeline)
// — normalises both outputs and reports field-level differences.
//
// Differences are the DELIVERABLE, not a failure: exit code is 0 whenever the
// comparison ran, regardless of how many entries diverge. Read the report.
//
// Usage: node canboat-parity-compare.cjs /path/to/canboatjs-checkout
// Output: JSON report on stdout, human summary on stderr.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const checkout = process.argv[2]
if (!checkout || !fs.existsSync(path.join(checkout, 'test', 'pgns'))) {
  console.error('usage: canboat-parity-compare.cjs <canboatjs-checkout-with-test/pgns>')
  process.exit(2)
}

// Fail fast when the analyzer is not runnable (e.g. the image was built
// without INSTALL_CANBOAT=1) — otherwise every entry would be reported as
// analyzer_undecoded, which reads as total divergence instead of a broken
// harness.
{
  const probe = spawnSync('analyzer', ['-version'], { encoding: 'utf8' })
  if (probe.error || probe.status !== 0) {
    console.error(
      `analyzer is not runnable (${probe.error ? probe.error.code : 'exit ' + probe.status}) — is this a canboat-enabled image?`
    )
    process.exit(2)
  }
}

let harnessErrors = 0

const { FromPgn } = require('/home/node/signalk/node_modules/@canboat/canboatjs')

// Drop keys the upstream test runner also ignores, plus nulls: analyzer's
// -json skips empty fields while FromPgn({returnNulls:true}) emits them, so
// null-vs-absent is presentation, not a decode difference.
function normalize(v) {
  if (Array.isArray(v)) return v.map(normalize)
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v).sort()) {
      if (['timestamp', 'input', 'id', 'bus'].includes(k)) continue
      if (v[k] === null || v[k] === undefined) continue
      out[k] = normalize(v[k])
    }
    return out
  }
  return v
}

function diffPaths(a, b, prefix, out) {
  const keys = new Set([...Object.keys(a || {}), ...Object.keys(b || {})])
  for (const k of keys) {
    const pa = a ? a[k] : undefined
    const pb = b ? b[k] : undefined
    const p = prefix ? `${prefix}.${k}` : k
    if (typeof pa === 'object' && typeof pb === 'object' && pa && pb && !Array.isArray(pa) && !Array.isArray(pb)) {
      diffPaths(pa, pb, p, out)
    } else if (JSON.stringify(pa) !== JSON.stringify(pb)) {
      out.push({ field: p, canboat: pa === undefined ? '<absent>' : pa, canboatjs: pb === undefined ? '<absent>' : pb })
    }
  }
}

// In -camel mode the analyzer (since canboat v6.0.0) wraps every message in
// a single-key envelope keyed by the camelCase PGN name:
//   {"systemTime": {"prio":3,"pgn":126992,...,"fields":{...}}}
// canboatjs emits the flat inner object, so unwrap before comparing. (This
// same envelope is what breaks signalk-server's native pipeline upstream —
// n2kAnalyzer pushes the wrapped object straight into n2k-signalk's
// toDelta, which expects the flat form. See the parity report.)
function unwrapCamel(obj) {
  const keys = Object.keys(obj)
  if (keys.length === 1 && obj[keys[0]] && typeof obj[keys[0]] === 'object' && 'pgn' in obj[keys[0]]) {
    return obj[keys[0]]
  }
  return obj
}

function runAnalyzer(lines) {
  const res = spawnSync('analyzer', ['-json', '-si', '-camel'], {
    input: lines.join('\n') + '\n',
    encoding: 'utf8',
    timeout: 30000
  })
  // res.error / res.signal mean the harness could not run the analyzer
  // (missing binary, timeout kill). A plain non-zero exit is the analyzer
  // legitimately rejecting input it cannot parse — that is a decode result
  // (analyzer_undecoded), not a harness failure.
  if (res.error || res.signal) {
    console.error(
      `analyzer run failed: ${res.error ? res.error.message : res.signal}`
    )
    harnessErrors++
    return []
  }
  const decoded = []
  for (const line of (res.stdout || '').split('\n')) {
    const t = line.trim()
    if (!t.startsWith('{')) continue
    try {
      const obj = JSON.parse(t)
      if (obj.version && !obj.pgn) continue // v8 startup header line
      decoded.push(unwrapCamel(obj))
    } catch {
      /* non-JSON noise */
    }
  }
  return decoded
}

function runCanboatjs(lines, format) {
  let decoded = null
  const parser = new FromPgn({ format, returnNulls: true, useCamel: true })
  parser.on('error', () => {})
  parser.on('warning', () => {})
  parser.on('pgn', () => {})
  for (const line of lines) {
    const pgn = parser.parseString(line)
    if (pgn) decoded = pgn
  }
  return decoded
}

const results = []
const pgnsDir = path.join(checkout, 'test', 'pgns')
for (const file of fs.readdirSync(pgnsDir).sort()) {
  if (!file.endsWith('.js')) continue
  const entries = require(path.join(pgnsDir, file))
  entries.forEach((entry, idx) => {
    if (!entry.input) return
    const lines = Array.isArray(entry.input) ? entry.input : [entry.input]
    const format = entry.format === undefined ? 1 : entry.format
    const cb = runAnalyzer(lines)
    const cbjs = runCanboatjs(lines, format)
    const pgn = entry.expected && entry.expected.pgn

    const rec = { file, idx, pgn }
    if (cb.length === 0 && !cbjs) rec.status = 'both_undecoded'
    else if (cb.length === 0) rec.status = 'analyzer_undecoded'
    else if (!cbjs) rec.status = 'canboatjs_undecoded'
    else {
      const a = normalize(cb[cb.length - 1])
      const b = normalize(cbjs)
      const diffs = []
      diffPaths(a, b, '', diffs)
      rec.status = diffs.length === 0 ? 'match' : 'diff'
      if (diffs.length) rec.diffs = diffs
    }
    results.push(rec)
  })
}

const counts = {}
for (const r of results) counts[r.status] = (counts[r.status] || 0) + 1
console.log(JSON.stringify({ counts, results }, null, 2))
console.error(`canboat-parity: ${results.length} entries — ${JSON.stringify(counts)}`)
if (harnessErrors > 0) {
  console.error(`${harnessErrors} analyzer invocations failed — report is incomplete`)
  // exitCode, not process.exit(): the report above may still be flushing.
  process.exitCode = 2
}
