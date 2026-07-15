# rerere-cache

Pre-recorded `git rerere` conflict resolutions, copied into the fresh clone by
`build-dirkwa.yml` before the PR-stack merge loop so a **known, reviewed**
merge conflict resolves automatically instead of failing the build.

## Why this exists

The `:dirkwa` image stacks several open upstream PRs onto `master`. Two of them
touch the same import region in `src/api/index.ts`:

- **#2588** (BLE Provider API) adds `import { BLEApi } from './ble'`
- **#2837** (default History API provider) rewrites the adjacent line to
  `import { HistoryApiHttpRegistry, HistoryApplication } from './history'`

Merged together the two adjacent import edits collide. The resolution is the
trivial union of both lines. Rather than resolve it by hand on every scheduled
run (the merge happens in CI, in a throwaway clone), the resolution is recorded
here once and replayed via rerere.

Each subdirectory is one recorded conflict, keyed by rerere's hash of the
conflict *preimage*:

- `preimage`  — the conflict as git first produced it (the hash is derived from this)
- `postimage` — the resolved form to replay

## How the workflow uses it

`build-dirkwa.yml` sets `rerere.enabled` + `rerere.autoupdate` and copies this
directory into `signalk-src/.git/rr-cache/` after cloning. When a stacked merge
hits the recorded conflict, rerere re-applies the postimage and stages it; the
merge loop then checks `git rerere remaining` — empty means fully resolved, so
it commits and continues; non-empty means a *new/unrecorded* conflict, so it
fails the build (never auto-resolves something unreviewed).

## Regenerating (when a PR updates and the recorded resolution stops matching)

If the conflicting import region changes, the preimage hash changes and this
cache goes stale — the build fails with a genuine unresolved conflict. Rebuild
it:

```bash
git clone https://github.com/SignalK/signalk-server.git /tmp/rr && cd /tmp/rr
git config rerere.enabled true
git config rerere.autoupdate true
git checkout master
# merge the stack in the SAME order as PRS in build-dirkwa.yml
for pr in 2588 2524 2837; do
  git fetch origin "pull/$pr/head:pr-$pr"
  git merge --no-ff --no-edit -m "Merge #$pr" "pr-$pr" || {
    # resolve src/api/index.ts to the union of both imports, then:
    git add -A && git commit --no-edit
  }
done
# copy the freshly recorded resolution back over this directory:
rm -rf <repo>/rerere-cache/*
cp -r .git/rr-cache/* <repo>/rerere-cache/
```

Keep the `README.md` (this file) — it is ignored by the copy into `.git/rr-cache`
because rerere only reads hash-named subdirectories.
