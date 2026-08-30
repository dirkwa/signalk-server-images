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
| `dirkwa` | master + a personal stack of upstream PRs and branches, an unreleased `@signalk/n2k-signalk`, `@canboat/wasm`, and a bundled `bt-sensors-plugin-sk` | every 3 h (+45 min offset) |
| `dirkwa-<sha7>` | Pinned commit on the merged stack | published alongside `dirkwa` |

Each workflow only builds and pushes when the resolved upstream version (or commit SHA) differs from what's in `state/`. Re-runs against unchanged upstream are no-ops.

### What `:dirkwa` carries beyond master

The exact stack is the `PRS:`, `BRANCHES:`, `N2K_SIGNALK_*` and `BT_SENSORS_*`
envs in `.github/workflows/build-dirkwa.yml` — that file is the source of
truth, and each entry's resolved SHA is recorded in the image labels
(`io.dirkwa.signalk.prs`, `io.dirkwa.signalk.branches`,
`io.dirkwa.n2k-signalk.version`, `io.dirkwa.bt-sensors.version`,
`io.dirkwa.canboat-wasm.version`).

#### canboat N2K decoding

N2K decoding uses [`@canboat/wasm`](https://www.npmjs.com/package/@canboat/wasm)
— the same canboat code compiled to WebAssembly, decoding and encoding
in-process. The version is recorded in the `io.dirkwa.canboat-wasm.version`
label.

The prebuilt **native** canboat C tools are *not* installed by default
(`INSTALL_CANBOAT: "0"`): the wasm build covers the same ground without
shipping binaries, and `canbus` keeps canboatjs's `canSocket` shim as its
frame mover. Because signalk-server only offers the native connection types
when `analyzer` is found on `PATH`, those `hasAnalyzer`-gated options do not
appear in the connection editor. Set `INSTALL_CANBOAT: "1"` in the workflow
to bring them back.

Notes on decoding behaviour:

- **canboatjs remains the default.** Nothing changes unless you explicitly
  pick a non-canboatjs connection type.
- **Outbound PGN encoding always goes through canboatjs** on a native
  connection — plugins that transmit are unaffected either way.
- Downgrading to an image without the tools while a connection is configured
  for a native type makes that connection fail with an error (it does not
  silently mis-decode). Switch the connection type back first.

#### Bundled `bt-sensors-plugin-sk`

The image ships [bt-sensors-plugin-sk](https://github.com/naugehyde/bt-sensors-plugin-sk)
built from `dirkwa/bt-sensors-plugin-sk:ble-gateway-api-support`, which makes
the plugin follow the server's own BLE settings (use the server's BLE API when
it manages Bluetooth, hybrid otherwise). Upstream PR
[#137](https://github.com/naugehyde/bt-sensors-plugin-sk/pull/137) was closed
unmerged, and no published release carries the change.

It installs as a **bundled** plugin (in the server's own `node_modules`, not
`~/.signalk`), is enabled by default on a fresh config, and its App Store
update button is greyed out — taking a published "update" would install into
`~/.signalk/node_modules`, which takes precedence and would silently revert to
a build without the BLE-API integration. Installing it there deliberately
still works, and is the way to move to a real upstream release once one exists.

BLE itself needs the host's Bluetooth stack: the image ships no `bluez`, so
bind-mount the host `/run/dbus` — see [BLE plugins](#ble-plugins) below.

`scripts/canboat-parity.sh` (dev tool) decodes the canboatjs test corpus
through both paths and reports field-level differences.

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

## Node-RED with a remote Victron GX device

Node-RED is **not** part of this image. `@signalk/signalk-node-red` is an app store plugin, and the Victron nodes (`node-red-contrib-victron`) are installed from within Node-RED via *Manage palette*. No image update ships or updates either of them.

To let those nodes reach a GX device (Cerbo/Venus) that is **not** the machine running SignalK, enable "Insecure D-Bus over TCP" on the GX device (`Settings -> Services`, or `/Settings/Services/InsecureDbusOverTcp = 1`), **reboot the GX device**, and set:

```yaml
environment:
  - NODE_RED_DBUS_ADDRESS=192.168.1.4:78
```

As the name says, "Insecure D-Bus over TCP" is **unauthenticated and unencrypted**: anyone who can reach port 78 gets full read/write control of the GX device. Only enable it on a trusted network, firewall the port to the SignalK host, and never expose it to the Internet. Use a VPN for remote access.

Three things that reliably go wrong:

- **The `-e` prefix.** With `docker run` the flag is `-e NODE_RED_DBUS_ADDRESS=192.168.1.4:78`. In compose, the leading `-` is YAML list syntax and the `-e` must be dropped. Carrying it over creates a variable literally named `-e NODE_RED_DBUS_ADDRESS`, which is silently ignored.
- **The address syntax.** Plain `host:port`. The `tcp:host=192.168.1.4,port=78` form is what `signalk-venus-plugin` wants; the Node-RED nodes reject it. When the value does not parse, the virtual-device node falls back to the *local* system bus and logs `org.freedesktop.DBus.Error.ServiceUnknown` in a retry loop, plus `The name com.victronenergy.settings was not provided by any .service files`.
- **Setting `DBUS_SYSTEM_BUS_ADDRESS` instead.** That redirects the whole server rather than just the Victron nodes, and has been seen to break the core with `.dbus-keyrings` errors. Use `NODE_RED_DBUS_ADDRESS`, which only the Victron nodes read.

Verify the value actually reached the container with `docker exec <container> printenv NODE_RED_DBUS_ADDRESS`. Changing it requires recreating the container, not just restarting it.

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

The contents of this repository — the Dockerfile, `startup.sh`, `scripts/`,
workflows and the way the images are assembled — are **source available, not
open source**. See [LICENSE.md](LICENSE.md).

**You may**, free of charge: run the images and build scripts on your own boat
or fleet, private or commercial; use them for internal company operations;
modify them for your own use; use them in non-commercial education and
research; and provide professional services to others who use them under these
terms.

**You may not**: redistribute modified versions or derivative works of the
build scripts or images, or publish them to a registry or elsewhere. The images
this repository's workflows publish to `ghcr.io/dirkwa/` are the releases
published by the licensor ("unofficial" above only means "not from the Signal K
project"); unmodified copies of them may be mirrored, cached and redistributed
verbatim as long as the notices stay intact and a copy of or link to the
license terms is included.

The software inside the images keeps its own license: signalk-server is
Apache-2.0 (see upstream), and Ubuntu, Node.js, canboat, podman and the other
packages carry theirs. Nothing here changes those. A copy of LICENSE.md is
shipped inside every image at `/usr/share/doc/signalk-server-images/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
