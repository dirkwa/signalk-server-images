# syntax=docker/dockerfile:1.7

# Unofficial SignalK server Docker image
#
# Build args:
#   SIGNALK_VERSION  npm version string (e.g. 2.27.0, 2.28.0-beta.1) when SOURCE=npm
#                    ignored when SOURCE=git
#   SIGNALK_SOURCE   one of: npm | git
#   SIGNALK_GIT_REF  git ref (branch, tag, sha) when SOURCE=git; default: master
#   NODE_MAJOR       Node.js major version installed via NodeSource (default 24)
#   STRIP_PACKAGES   space-separated npm package names to delete after install,
#                    e.g. "@signalk/instrumentpanel" — for dropping bundled
#                    webapps from a variant. Default: keep everything.
#   INSTALL_CANBOAT  "1" installs canboat's prebuilt C tools (analyzer etc.),
#                    activating signalk-server's native N2K decode path.
#                    Default off so :latest/:beta/:master keep mirroring
#                    upstream behaviour; only build-dirkwa.yml enables it.
#   CANBOAT_VERSION  canboat release tag whose prebuilt C tools are installed
#                    when INSTALL_CANBOAT=1. Only the v8.0.0 prereleases
#                    publish Linux binaries — stable tags (<= v7.1.0) ship
#                    Windows-only.

ARG NODE_MAJOR=24
ARG INSTALL_CANBOAT=0
ARG CANBOAT_VERSION=v8.0.0-beta1
# CANBOAT_SOURCE=release installs the sha256-pinned prebuilt C tools (the
# default); =git builds the Rust `canboat` binary from CANBOAT_REPO@
# CANBOAT_REF instead — its argv[0] shims provide every tool the server
# pipeline invokes (analyzer, actisense-serial, socketcan-serial,
# ikonvert-serial, maretron-ipg) PLUS `canboat convert --from json`, the
# native outbound encoder. Used to test canboat PR branches before release.
ARG CANBOAT_SOURCE=release
ARG CANBOAT_REPO=canboat/canboat
ARG CANBOAT_REF=master

# -----------------------------------------------------------------------------
# Stage 0: canboat-build — Rust canboat binary, only consumed when
# CANBOAT_SOURCE=git. Static musl build (same treatment as upstream's keel
# release) so the binary is glibc-independent. The stage always parses but
# its RUN exits immediately unless INSTALL_CANBOAT=1 AND CANBOAT_SOURCE=git,
# so release-mode builds never pay the Rust compile.
# -----------------------------------------------------------------------------
FROM rust:1-slim-trixie AS canboat-build
ARG INSTALL_CANBOAT
ARG CANBOAT_SOURCE
ARG CANBOAT_REPO
ARG CANBOAT_REF
RUN set -eux; \
  mkdir -p /out; \
  if [ "$INSTALL_CANBOAT" != "1" ] || [ "$CANBOAT_SOURCE" != "git" ]; then \
    echo "canboat git build skipped (INSTALL_CANBOAT=$INSTALL_CANBOAT CANBOAT_SOURCE=$CANBOAT_SOURCE)"; \
    exit 0; \
  fi; \
  apt-get update && apt-get -y install --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*; \
  # Fetch-by-ref rather than clone --branch so CANBOAT_REF can be a commit
  # SHA. The workflow passes the RESOLVED head SHA, not the branch name —
  # a branch-name arg is identical across builds, so BuildKit would reuse
  # this layer from cache and silently ship a stale binary after the
  # branch moves.
  mkdir /src && cd /src && git init -q && git remote add origin "https://github.com/$CANBOAT_REPO.git"; \
  git fetch -q --depth 1 origin "$CANBOAT_REF" && git checkout -q FETCH_HEAD; \
  cd /; \
  target="$(uname -m)-unknown-linux-musl"; \
  rustup target add "$target"; \
  cargo build --release --manifest-path /src/Cargo.toml -p canboat --target "$target"; \
  cp "/src/target/$target/release/canboat" /out/canboat; \
  /out/canboat --version

# -----------------------------------------------------------------------------
# Stage 1: base — OS, system packages, Node, container CLIs, user
# -----------------------------------------------------------------------------
FROM ubuntu:26.04 AS base

ARG NODE_MAJOR
ARG INSTALL_CANBOAT
ARG CANBOAT_VERSION
ARG CANBOAT_SOURCE
ARG CANBOAT_REPO
ARG CANBOAT_REF
ENV DEBIAN_FRONTEND=noninteractive

# Replace Ubuntu's default uid:1000 user with `node` (matches upstream convention)
RUN userdel -r ubuntu 2>/dev/null || true \
 && groupadd --gid 1000 node \
 && useradd --uid 1000 --gid node --shell /bin/bash --create-home node

# Core system packages. No avahi-DAEMON (no second mDNS responder — the server
# announces itself via pure-JS @astronautlabs/mdns). But libnss-mdns IS
# included: it is the glibc NSS module that lets getaddrinfo()/dns.lookup()
# resolve other devices' .local hostnames (e.g. a plugin reaching a Shelly at
# shelly-xxxx.local) — pure-JS mDNS only ANNOUNCES, it never intercepts
# getaddrinfo, so without this any .local lookup returns EAI_AGAIN. Pulled with
# --no-install-recommends so avahi-daemon does NOT come along (it is a
# Recommends, not a Depends); only the NSS module + avahi client libs land
# (~144 KB, no daemon, no 5353 binder). The module resolves via the HOST's avahi
# over a bind-mounted /run/avahi-daemon/socket (the installer Quadlet mounts it;
# plain-Docker users add a volumes: line) and needs the mdns line in
# /etc/nsswitch.conf below. No bluez — BLE plugins bind-mount host /run/dbus and
# use host bluez.
RUN apt-get update \
 && apt-get -y install --no-install-recommends \
      ca-certificates curl git sudo \
      python3 python3-venv python3-pip build-essential \
      libcap2-bin procps sysstat nano jq \
      uidmap fuse-overlayfs \
      libnss-mdns \
 && groupadd -r docker -g 991 \
 && groupadd -r i2c -g 990 \
 && groupadd -r spi -g 989 \
 && (getent group netdev >/dev/null || groupadd -r netdev) \
 && (getent group dialout >/dev/null || groupadd -r dialout) \
 && usermod -a -G dialout,i2c,spi,netdev,docker node \
 && sed -i -E 's/^(hosts:[[:space:]]+)(.*)$/\1files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf \
 && rm -rf /var/lib/apt/lists/*

# Node.js via NodeSource (nodistro suite = codename-agnostic, survives base bumps)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get -y install --no-install-recommends nodejs \
 && npm config rm proxy 2>/dev/null || true \
 && npm config rm https-proxy 2>/dev/null || true \
 && npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 60000 \
 && npm config set fetch-retry-maxtimeout 120000 \
 && npm cache clean -f \
 && npm install -g npm@latest \
 && rm -rf /var/lib/apt/lists/*

# canboat C tools (INSTALL_CANBOAT=1, i.e. :dirkwa only) — activates
# signalk-server's NATIVE NMEA 2000 decode path. The server already ships a
# complete non-canboatjs N2K pipeline (N2kAnalyzer -> N2kToSignalK, spawning
# `analyzer -json -si -camel`); it is inert only because the admin UI gates
# the connection options on GET /skServer/hasAnalyzer ==
# commandExists('analyzer'). Putting `analyzer` on PATH un-greys "Actisense
# NGT-1" and the native canbus subtype with ZERO source changes in
# signalk-server, n2k-signalk, canboatjs or any plugin. That is also why the
# default is OFF: installing this in the shared base would silently change
# the connection editor in :latest/:beta/:master, which mirror upstream.
# canboatjs remains the default and still performs ALL outbound PGN encoding
# (execute.ts pgnToActisenseSerialFormat) even for native connections — hence
# the allow-scripts/canSocket.node machinery below stays untouched.
# Only the binaries the server pipeline invokes are symlinked (analyzer plus
# the per-gateway bridge tools); the rest of /opt/canboat stays off PATH so
# an unrelated tool name can never shadow anything. Renaming/relocating the
# `analyzer` symlink silently removes the UI options — commandExists probes
# that exact name. can-utils provides `candump`/`cansend` for ad-hoc CAN
# debugging and is installed here, not in the core list, to keep the gate
# airtight.
# The tarball is digest-pinned per version+arch (release assets are mutable);
# bumping CANBOAT_VERSION means adding the new sha256 lines below, and any
# unlisted combination fails the build rather than trusting the download.
# Assertions mirror the canSocket.node pattern: fail the build loudly, not at
# sea. The -version run also catches an arch or glibc mismatch at build time.
COPY --from=canboat-build /out/ /tmp/canboat-rust/
RUN set -eux; \
  if [ "$INSTALL_CANBOAT" != "1" ]; then \
    echo "INSTALL_CANBOAT=$INSTALL_CANBOAT — skipping canboat tools"; \
    rm -rf /tmp/canboat-rust; \
    exit 0; \
  fi; \
  apt-get update; \
  apt-get -y install --no-install-recommends can-utils; \
  rm -rf /var/lib/apt/lists/*; \
  mkdir -p /opt/canboat; \
  if [ "$CANBOAT_SOURCE" = "git" ]; then \
    # The single Rust binary from the canboat-build stage: every tool the
    # server pipeline invokes is an argv[0] shim of it (candump2analyzer
    # has no shim, but nothing uses it since canbus switched to
    # socketcan-serial), and `canboat` itself is on PATH for
    # `convert --from json` — the native outbound encoder.
    install -m 0755 /tmp/canboat-rust/canboat /opt/canboat/canboat; \
    for b in canboat analyzer actisense-serial maretron-ipg ikonvert-serial socketcan-serial; do \
      ln -sf /opt/canboat/canboat "/usr/local/bin/$b"; \
      command -v "$b" >/dev/null || { echo "$b not on PATH after symlink" >&2; exit 1; }; \
    done; \
    canboat --version; \
  else \
    case "$(dpkg --print-architecture)" in \
      amd64) CB_ARCH=x86_64 ;; \
      arm64) CB_ARCH=aarch64 ;; \
      *) echo "unsupported architecture for canboat: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    case "${CANBOAT_VERSION}-${CB_ARCH}" in \
      v8.0.0-beta1-x86_64)  CB_SHA256=85920250b1b704ed2a7d5665f82039a72295347d630d3b78d6e7c2633a683a97 ;; \
      v8.0.0-beta1-aarch64) CB_SHA256=66e4ef05cea367c66992c897b41df6fa827e231b65fab545d9b4a4487c9ebb6d ;; \
      *) echo "no pinned sha256 for canboat ${CANBOAT_VERSION} on ${CB_ARCH} — add the digest here when bumping CANBOAT_VERSION" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/canboat.tgz \
      "https://github.com/canboat/canboat/releases/download/${CANBOAT_VERSION}/canboat-linux-${CB_ARCH}-${CANBOAT_VERSION}.tar.gz"; \
    echo "${CB_SHA256}  /tmp/canboat.tgz" | sha256sum -c - >/dev/null; \
    tar xzf /tmp/canboat.tgz -C /opt/canboat; \
    rm -f /tmp/canboat.tgz; \
    for b in analyzer actisense-serial candump2analyzer maretron-ipg ikonvert-serial socketcan-serial; do \
      test -x "/opt/canboat/$b" || { echo "canboat tarball is missing $b" >&2; exit 1; }; \
      ln -sf "/opt/canboat/$b" "/usr/local/bin/$b"; \
      command -v "$b" >/dev/null || { echo "$b not on PATH after symlink" >&2; exit 1; }; \
    done; \
  fi; \
  rm -rf /tmp/canboat-rust; \
  analyzer -version >/dev/null || { echo "analyzer present but not executable (arch/glibc mismatch?)" >&2; exit 1; }; \
  command -v candump >/dev/null || { echo "candump missing after can-utils install" >&2; exit 1; }

# Container runtime CLIs (mirrors SignalK/signalk-server PR #2695):
# plugins like signalk-container/questdb/grafana need to drive a host-mounted
# socket. docker-ce-cli from Docker's APT repo (Ubuntu's docker.io pulls the daemon).
# Both amd64 and arm64 are published for the resolute codename.
RUN apt-get update \
 && apt-get -y install --no-install-recommends podman \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu resolute stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get -y install --no-install-recommends docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

# Default podman service destination → host docker/podman socket if mounted.
# Lets in-container `podman info` etc. work without CONTAINER_HOST being set.
COPY containers.conf /etc/containers/containers.conf

# -----------------------------------------------------------------------------
# Stage 2: install — fetch SignalK server, lay out node_modules
# -----------------------------------------------------------------------------
FROM base AS install

ARG SIGNALK_VERSION
ARG SIGNALK_SOURCE=npm
ARG SIGNALK_GIT_REF=master
ARG STRIP_PACKAGES=""

USER node
WORKDIR /home/node/signalk

RUN mkdir -p /home/node/.signalk

# npm >= 12 gates dependency lifecycle scripts behind an approval list and
# SKIPS unapproved ones (only a `npm warn install-scripts` hints at it).
# @canboat/canboatjs compiles its SocketCAN addon in its install script
# (`node-gyp rebuild || echo '...'`) — the `|| echo` makes the skip silent,
# which shipped images where canbus-canboatjs could not open can0 (npm 11 ->
# 12 bump via npm@latest, 2026-07). Approve exactly that package via a
# project-scoped .npmrc: `--allow-scripts` on the command line is rejected
# for project installs (EALLOWSCRIPTS), and this stays scoped to
# /home/node/signalk — runtime appstore installs run in /home/node/.signalk
# and remain gated. The assertion after the install below fails the build
# loudly if the addon is ever missing again.
RUN printf 'allow-scripts[]=@canboat/canboatjs\n' > /home/node/signalk/.npmrc

# When SOURCE=local, the workflow places a pre-prepared signalk-server checkout
# at ./signalk-src/ in the build context (e.g. master + a stack of merged PRs).
# When SOURCE != local, the dir contains just a .keep placeholder which we
# ignore. Either way the COPY succeeds.
COPY --chown=node:node ./signalk-src/ /tmp/signalk-src/

# npm path: install signalk-server@<version> from registry.
# git path: clone master/branch, build:all, pack workspaces + root.
# local path: same as git but uses the pre-staged /tmp/signalk-src instead of
#   cloning. Lets the workflow merge PR branches before building.
# After install, relocate @signalk/* and @mxtommy/kip into the nested
# node_modules/signalk-server/node_modules/ tree the admin UI expects.
# STRIP_PACKAGES removal happens at the end of the SAME RUN so the deleted
# bytes never persist in any layer (a later RUN would only mask them).
RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000,sharing=locked \
    set -eux; \
  build_from_src() { \
    cd "$1"; \
    npm install; \
    npm run build:all; \
    npm pack --workspaces; \
    npm pack; \
    rm -f signalk-typedoc-signalk-theme-*.tgz; \
    mkdir -p /tmp/skpack; \
    mv ./*.tgz /tmp/skpack/; \
    cd /home/node/signalk; \
    rm -rf "$1"; \
    npm install /tmp/skpack/*.tgz; \
    rm -rf /tmp/skpack; \
  }; \
  case "$SIGNALK_SOURCE" in \
    git) \
      git clone --depth=1 --branch="$SIGNALK_GIT_REF" \
        https://github.com/SignalK/signalk-server.git src; \
      build_from_src "$PWD/src"; \
      ;; \
    local) \
      if [ ! -f /tmp/signalk-src/package.json ]; then \
        echo "SIGNALK_SOURCE=local but ./signalk-src/ does not contain a signalk-server checkout" >&2; \
        exit 1; \
      fi; \
      build_from_src /tmp/signalk-src; \
      ;; \
    npm) \
      if [ -z "$SIGNALK_VERSION" ]; then \
        echo "SIGNALK_VERSION is required when SIGNALK_SOURCE=npm" >&2; exit 1; \
      fi; \
      npm install "signalk-server@$SIGNALK_VERSION"; \
      ;; \
    *) \
      echo "Unknown SIGNALK_SOURCE: $SIGNALK_SOURCE" >&2; exit 1; \
      ;; \
  esac; \
  test -f node_modules/@canboat/canboatjs/build/Release/canSocket.node || { \
    echo "canboatjs native canSocket addon missing — npm skipped install scripts (allow-scripts gate)?" >&2; \
    exit 1; \
  }; \
  mkdir -p node_modules/signalk-server/node_modules/@signalk/; \
  if [ -d node_modules/@signalk ]; then \
    cp -rf node_modules/@signalk/* node_modules/signalk-server/node_modules/@signalk/; \
    rm -rf node_modules/@signalk/; \
  fi; \
  mkdir -p node_modules/signalk-server/node_modules/@mxtommy/; \
  if [ -d node_modules/@mxtommy/kip ]; then \
    cp -rf node_modules/@mxtommy/kip node_modules/signalk-server/node_modules/@mxtommy/; \
    rm -rf node_modules/@mxtommy/; \
  fi; \
  for p in $STRIP_PACKAGES; do \
    echo "Stripping $p"; \
    rm -rf "node_modules/$p" "node_modules/signalk-server/node_modules/$p"; \
  done

COPY --chown=node:node --chmod=755 startup.sh /home/node/signalk/startup.sh

# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------
FROM install AS final

USER node
WORKDIR /home/node/.signalk

# SIGNALK_SERVER_IS_UPDATABLE makes the server compute the "new version
# available" footer notice even though it is launched from a local
# (non-system) install path. The self-update button stays hidden via
# IS_IN_DOCKER, which gates canUpdateServer separately.
ENV SKIP_ADMINUI_VERSION_CHECK=true \
    IS_IN_DOCKER=true \
    SIGNALK_SERVER_IS_UPDATABLE=true

EXPOSE 3000

ENTRYPOINT ["/home/node/signalk/startup.sh"]
