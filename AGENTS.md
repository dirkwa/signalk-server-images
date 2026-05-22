# Agent guide — signalk-server-images

This repo builds unofficial Docker images of [SignalK/signalk-server](https://github.com/SignalK/signalk-server). It is a **builder**, not a fork — no SignalK source lives here.

## Mental model

Three streams, three workflows, one Dockerfile that branches on a build arg:

| Workflow | Trigger | Source mode | Output tag |
|---|---|---|---|
| `build-latest.yml` | every 6 h | `SIGNALK_SOURCE=npm` + `SIGNALK_VERSION=<semver>` | `:latest`, `:vX.Y.Z` |
| `build-beta.yml` | every 6 h (+30 min) | `SIGNALK_SOURCE=npm` + beta version | `:beta`, `:vX.Y.Z-beta.N` |
| `build-master.yml` | every 3 h | `SIGNALK_SOURCE=git` + `SIGNALK_GIT_REF=master` | `:master`, `:master-<sha7>` |
| `build-dirkwa.yml` | every 3 h (+45 min) | `SIGNALK_SOURCE=local` (a pre-staged dir) | `:dirkwa`, `:dirkwa-<sha7>` |
| `manual.yml` | workflow_dispatch | any | pinned tag |

Every scheduled workflow is a **no-op when upstream hasn't moved.** The shape is: resolve upstream identity (npm dist-tag, GH release tag, commit SHA, or composite SHA tuple), compare to a committed state file, exit early if equal. Re-runs cost ~5 s of CI when nothing changed.

## Things that look wrong but aren't — read before "fixing"

- **The `cp -rf node_modules/@signalk/* node_modules/signalk-server/node_modules/@signalk/` shuffle.** The admin UI walks the *nested* `node_modules/signalk-server/node_modules/` tree to discover workspace packages. Hoisting (which npm does by default) breaks it. Mirrors upstream's `Dockerfile_rel`.
- **No avahi/dbus in the image.** signalk-server 2.27+ uses pure-JS `@astronautlabs/mdns` (raw UDP multicast). Adding avahi back wastes ~80 MB and runs a daemon nobody asks for. With `--network=host` mDNS just works.
- **No bluez in the image.** Ubuntu 26.04's `bluez` package grabs GID 991, colliding with our `docker` group. BLE plugins should bind-mount host `/run/dbus` and use the host's bluez stack — documented in README.
- **Both `podman` and `docker-ce-cli` ship.** Plugins like `signalk-container`, `signalk-questdb`, `signalk-grafana` drive a bind-mounted host socket. Some hosts run docker, some podman; shipping both lets either work. Adds ~145 MB, intentional. Mirrors upstream PR #2695.
- **`npm install`, not `npm ci`, on the git source path.** signalk-server gitignores `package-lock.json`. There's no lockfile to ci against. Do not "fix" this by trying to use `npm ci`.
- **`npm pack --workspaces` writes into the source dir, not `--pack-destination=`.** The `--pack-destination` flag ENOENTs on the first workspace tarball due to an npm race. Pack into source dir, then `mv ./*.tgz /tmp/skpack/`. Mirrors upstream's `build-docker.yml`.
- **The BuildKit cache mount has `sharing=locked`, not `shared`.** Concurrent runs serialize on the cache to avoid corruption. Don't change to `shared`.
- **No `npm cache clean -f` at the end of install.** The cache lives in the mount, not the layer. Cleaning would just force a re-download next run.
- **State files live in `state/*.txt` and are committed by the workflows themselves.** Not a GHA cache, not a repo variable, not an issue body. The git history is the audit trail. Concurrent commits use `scripts/commit-state.sh` which pulls --rebase + retries up to 5 times.

## Conventions the maintainer has set

- **Commits**: Angular conventional commit format (`fix(workflows): ...`, `feat(dirkwa): ...`, `chore(state): ...`).
- **No Co-Authored-By trailers, no "Generated with Claude Code" attribution** anywhere — commit messages, PR bodies, comments, doc files.
- **Never push without explicit "push" or "merge" instruction.** Commit ≠ push.
- **Never create PRs without explicit instruction.** This repo is direct-to-main; no PR flow.
- **Never auto-commit or auto-trigger workflows on the maintainer's behalf** unless asked.
- **No emojis** in any output — commits, file contents, comments — unless explicitly asked.

## When you need to change something

- **Adding/removing a PR from the `:dirkwa` stack** → edit the `PRS:` env in `.github/workflows/build-dirkwa.yml`. That's the only source of truth. Composite state key auto-updates.
- **Bumping the SignalK minimum stable version** → `MIN_VERSION` in `build-latest.yml`. Workflow refuses to build below it.
- **Changing the base image (Ubuntu / Node)** → top of `Dockerfile`. Dependabot will eventually offer base-image bumps as PRs.
- **Adding a new image variant (e.g. `:nightly` from a feature branch)** → copy `build-master.yml`, change the env, ref, and tag. Reuse `.github/actions/build-and-push` and `scripts/commit-state.sh`.
- **Anything that changes the install logic** → also smoke-test all three source modes (`npm`, `git`, `local`) locally with `docker build --build-arg SIGNALK_SOURCE=...`. The `local` mode needs `./signalk-src/` populated; an empty dir with just `.keep` is the placeholder that lets the `COPY` succeed for `npm`/`git` modes.

## Pitfalls / scars

- **GHCR ACL stuckness.** If you flip a package's "Repository source" or visibility, per-platform manifests on already-pushed tags can keep the *old* ACL even when the index shows public. Symptoms: anonymous `tags/list` returns 200, anonymous index returns 200, anonymous per-arch manifest returns 404. Cure: delete the affected tag and re-push (workflows re-push fine). Tags with >5000 downloads can't be deleted — overwrite them by re-running the workflow with a state-file reset.
- **Workflow `permissions: packages: write` is clamped by repo default.** Repo's `Settings → Actions → Workflow permissions` must be set to "Read and write" (we set it via `gh api -X PUT /repos/.../actions/permissions/workflow`). Without that, GHCR push 401s even though the YAML claims write.
- **GitHub package settings UI lags reality** — deleted tags can keep showing up in the "install" snippet for several minutes after deletion. Trust `gh api /user/packages/.../versions`, not the page.
- **Concurrent state-file pushes race.** Two workflows finishing within the same window of each other will conflict. `scripts/commit-state.sh` handles this with rebase+retry. Don't simplify back to plain `git push`.

## Verification

Local smoke build:
```bash
docker build --build-arg SIGNALK_SOURCE=npm --build-arg SIGNALK_VERSION=2.27.0 -t sk:test .
docker run --rm -p 13000:3000 sk:test
curl -sS http://localhost:13000/signalk | jq .endpoints
```

Anonymous-pull check against GHCR:
```bash
TOKEN=$(curl -sS "https://ghcr.io/token?service=ghcr.io&scope=repository:dirkwa/signalk-server:pull" | jq -r .token)
curl -sS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/dirkwa/signalk-server/tags/list" | jq .
```
