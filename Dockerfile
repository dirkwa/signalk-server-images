# syntax=docker/dockerfile:1.7

# Unofficial SignalK server Docker image
#
# Build args:
#   SIGNALK_VERSION  npm version string (e.g. 2.27.0, 2.28.0-beta.1) when SOURCE=npm
#                    ignored when SOURCE=git
#   SIGNALK_SOURCE   one of: npm | git
#   SIGNALK_GIT_REF  git ref (branch, tag, sha) when SOURCE=git; default: master
#   NODE_MAJOR       Node.js major version installed via NodeSource (default 24)

ARG NODE_MAJOR=24

# -----------------------------------------------------------------------------
# Stage 1: base — OS, system packages, Node, container CLIs, user
# -----------------------------------------------------------------------------
FROM ubuntu:26.04 AS base

ARG NODE_MAJOR
ENV DEBIAN_FRONTEND=noninteractive

# Replace Ubuntu's default uid:1000 user with `node` (matches upstream convention)
RUN userdel -r ubuntu 2>/dev/null || true \
 && groupadd --gid 1000 node \
 && useradd --uid 1000 --gid node --shell /bin/bash --create-home node

# Core system packages (no avahi/dbus — server uses pure-JS @astronautlabs/mdns;
# no bluez — BLE plugins should bind-mount host /run/dbus and use host bluez).
RUN apt-get update \
 && apt-get -y install --no-install-recommends \
      ca-certificates curl git sudo \
      python3 python3-venv python3-pip build-essential \
      libcap2-bin procps nano \
 && groupadd -r docker -g 991 \
 && groupadd -r i2c -g 990 \
 && groupadd -r spi -g 989 \
 && (getent group netdev >/dev/null || groupadd -r netdev) \
 && (getent group dialout >/dev/null || groupadd -r dialout) \
 && usermod -a -G dialout,i2c,spi,netdev,docker node \
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

# -----------------------------------------------------------------------------
# Stage 2: install — fetch SignalK server, lay out node_modules
# -----------------------------------------------------------------------------
FROM base AS install

ARG SIGNALK_VERSION
ARG SIGNALK_SOURCE=npm
ARG SIGNALK_GIT_REF=master

USER node
WORKDIR /home/node/signalk

RUN mkdir -p /home/node/.signalk

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
RUN set -eux; \
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
  npm cache clean -f

COPY --chown=node:node --chmod=755 startup.sh /home/node/signalk/startup.sh

# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------
FROM install AS final

USER node
WORKDIR /home/node/.signalk

ENV SKIP_ADMINUI_VERSION_CHECK=true \
    IS_IN_DOCKER=true

EXPOSE 3000

ENTRYPOINT ["/home/node/signalk/startup.sh"]
