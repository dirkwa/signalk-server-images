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

### Two build patterns

The npm-mode workflows (`build-latest`, `build-beta`, `manual`) build multi-arch in a single buildx pass using `.github/actions/build-and-push`. QEMU emulation is fine there because the `signalk-server` npm tarball ships the admin UI pre-built, so the in-container `npm install` does no JS/TS compilation — just unpacks and resolves dependencies, both of which emulate cheaply.

The source-build workflows (`build-master`, `build-dirkwa`) fan out across **native runners** (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64) using `.github/actions/build-and-push-arch`, then a final `merge` job assembles a manifest list with `docker buildx imagetools create`. Native runners are mandatory here because `vite build` of `@signalk/server-admin-ui` pulls in `rolldown`, whose native bindings do not resolve under QEMU — `npm install` "succeeds" but the bindings for the emulated platform never install, so `vite build` then dies with `MODULE_NOT_FOUND` for the arm64 binding when emulated on amd64.

The source-build workflow shape is `prepare → build (matrix) → merge`:

1. **`prepare`** (single runner): resolves upstream identity, applies the state gate, optionally clones master and merges PR branches (dirkwa only), uploads the resulting tree as an `actions/upload-artifact@v4` artifact.
2. **`build`** (matrix, one job per platform on its native runner): downloads the prepared source if applicable, builds + pushes a single-arch image **by digest only** (no tag), uploads the digest as an artifact for the merge job to pick up.
3. **`merge`** (single runner): downloads both digest artifacts, calls `docker buildx imagetools create` with both digests under the same tag, then commits the state-file update via `scripts/commit-state.sh`.

Matrix job outputs cannot reliably aggregate across matrix entries — GitHub keeps the last entry's value rather than merging — so the per-arch digest passes through an `actions/upload-artifact` round-trip rather than a job output.

## Things that look wrong but aren't — read before "fixing"

- **The `cp -rf node_modules/@signalk/* node_modules/signalk-server/node_modules/@signalk/` shuffle.** The admin UI walks the *nested* `node_modules/signalk-server/node_modules/` tree to discover workspace packages. Hoisting (which npm does by default) breaks it. Mirrors upstream's `Dockerfile_rel`.
- **No avahi/dbus in the image.** signalk-server 2.27+ uses pure-JS `@astronautlabs/mdns` (raw UDP multicast). Adding avahi back wastes ~80 MB and runs a daemon nobody asks for. With `--network=host` mDNS just works.
- **No bluez in the image.** Ubuntu 26.04's `bluez` package grabs GID 991, colliding with our `docker` group. BLE plugins should bind-mount host `/run/dbus` and use the host's bluez stack — documented in README.
- **Both `podman` and `docker-ce-cli` ship.** Plugins like `signalk-container`, `signalk-questdb`, `signalk-grafana` drive a bind-mounted host socket. Some hosts run docker, some podman; shipping both lets either work. Adds ~145 MB, intentional. Mirrors upstream PR #2695.
- **`npm install`, not `npm ci`, on the git source path.** signalk-server gitignores `package-lock.json`. There's no lockfile to ci against. Do not "fix" this by trying to use `npm ci`.
- **`npm pack --workspaces` writes into the source dir, not `--pack-destination=`.** The `--pack-destination` flag ENOENTs on the first workspace tarball due to an npm race. Pack into source dir, then `mv ./*.tgz /tmp/skpack/`. Mirrors upstream's `build-docker.yml`.
- **The BuildKit cache mount has `sharing=locked`, not `shared`.** Concurrent runs serialize on the cache to avoid corruption. Don't change to `shared`.
- **No `npm cache clean -f` at the end of install.** The cache lives in the mount, not the layer. Cleaning would just force a re-download next run.
- **`uidmap` is in the apt list.** Without `newuidmap`/`newgidmap`, in-container rootless podman fails its first real call with `newuidmap: executable file not found in $PATH`. Cheap to install (~85 KB), removes a confusing error.
- **`fuse-overlayfs` is in the apt list.** Insurance for hosts whose backing filesystem (ZFS, some btrfs configs, eCryptfs) refuses kernel overlayfs. When podman picks up the binary it routes overlay-driver storage through userspace FUSE instead of falling back to `vfs` (which copies layers and is unusably slow). Cheap (~150 KB), no harm to hosts that don't need it.
- **`/etc/containers/containers.conf` ships in the image.** Sets the default podman service destination to `unix:///var/run/docker.sock`, so `podman info` etc. work out of the box when the host socket is bind-mounted — no `CONTAINER_HOST` env needed. Pairs with the rootless fallback in dirkwa/signalk-container (commit 3d97e69).
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
