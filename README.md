# signalk-server-images

Unofficial Docker images for [SignalK/signalk-server](https://github.com/SignalK/signalk-server), built automatically when upstream changes.

- Base: **Ubuntu 26.04 LTS (Resolute Raccoon)** + **Node.js 24** (latest npm)
- Multi-arch: `linux/amd64`, `linux/arm64`
- Ships **podman** and **docker-ce-cli** so plugins like `signalk-container`, `signalk-questdb` and `signalk-grafana` can drive a bind-mounted host socket
- Drops `avahi-daemon` / `dbus` (signalk-server 2.27+ uses pure-JS `@astronautlabs/mdns`)

Registry: `ghcr.io/dirkwa/signalk-server`

## Tags

| Tag | What it tracks | Update cadence |
|---|---|---|
| `latest` | Newest stable npm release of `signalk-server` (>= 2.27.0) | every 6 h |
| `vX.Y.Z` | Pinned stable release | published alongside `latest` |
| `beta` | Newest GitHub release tagged `vX.Y.Z-beta.N` | every 6 h (+30 min offset) |
| `vX.Y.Z-beta.N` | Pinned beta release | published alongside `beta` |
| `master` | HEAD of `SignalK/signalk-server` `master` branch | every 3 h |
| `master-<sha7>` | Pinned commit on master | published alongside `master` |
| `dirkwa` | master + a personal stack of upstream PRs (2628, 2588, 2694, 2690) merged in order | every 3 h (+45 min offset) |
| `dirkwa-<sha7>` | Pinned commit on the merged stack | published alongside `dirkwa` |

Each workflow only builds and pushes when the resolved upstream version (or commit SHA) differs from what's in `state/`. Re-runs against unchanged upstream are no-ops.

## Quick start

```bash
docker run --rm -it --network=host \
  -v "$PWD/signalk-data:/home/node/.signalk" \
  ghcr.io/dirkwa/signalk-server:latest
```

Admin UI at `http://<host>:3000/admin`.

See [docker-compose.example.yml](docker-compose.example.yml) for a fuller setup including USB devices, host networking, and the optional host-socket mount for container-orchestration plugins.

## Manual builds

`manual.yml` accepts any version or git ref via the GitHub Actions UI:

- Build a specific stable: source=`npm`, version=`2.27.0`
- Build a specific beta: source=`npm`, version=`2.28.0-beta.1`
- Build a feature branch: source=`git`, git_ref=`my-branch`
- Build a specific commit: source=`git`, git_ref=`<sha>`

Manual builds push a deterministic tag (`vX.Y.Z` or `git-<sha7>`) plus an optional `extra_tag`. They do not update the `state/` files.

## Local build

```bash
docker build \
  --build-arg SIGNALK_SOURCE=npm \
  --build-arg SIGNALK_VERSION=2.27.0 \
  -t signalk-server:test .

docker run --rm -p 3000:3000 signalk-server:test
```

For master builds:

```bash
docker build \
  --build-arg SIGNALK_SOURCE=git \
  --build-arg SIGNALK_GIT_REF=master \
  -t signalk-server:master .
```

## mDNS / Bonjour

The server advertises itself over mDNS using `@astronautlabs/mdns`, a pure-JS implementation. It needs raw UDP multicast access, which means:

- `--network=host` (Linux): works out of the box
- Bridge networking: mDNS advertisement does not cross the bridge boundary; the admin UI is still reachable on the published port, but other devices on the LAN will not see the SignalK service in their service browsers

## BLE plugins

`bluez` is **not** installed in the image. BLE plugins that need it should bind-mount the host's D-Bus and use the host's bluez stack:

```yaml
volumes:
  - /run/dbus:/run/dbus:ro
```

This is also the more reliable setup: a container-private bluez stack can't actually drive host Bluetooth radio without privileged hardware access anyway, and most BLE plugins are designed to work against the host D-Bus.

## Container-orchestration plugins

To let plugins talk to the host runtime, mount the appropriate socket at `/var/run/docker.sock`:

```yaml
# Docker host
volumes:
  - /var/run/docker.sock:/var/run/docker.sock

# Podman host (rootless example)
volumes:
  - /run/user/1000/podman/podman.sock:/var/run/docker.sock
```

Both `podman` and `docker` CLIs are present inside the image, so plugins can use whichever interface they prefer against either socket (podman's socket implements the docker API).

## Differences from the official `cr.signalk.io/signalk/signalk-server` image

- Newer base (26.04 vs 24.04), newer Node (24 vs 22)
- No avahi/dbus daemons running inside the container
- Container runtime CLIs included by default (upstream PR [#2695](https://github.com/SignalK/signalk-server/pull/2695))
- Single Dockerfile, no separate base-image tier
- Built only on upstream change, not on a fixed schedule

## License

This repo's build scripts: see [LICENSE](LICENSE).
SignalK server itself: Apache-2.0 (see upstream).
