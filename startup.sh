#!/usr/bin/env sh
set -e

exec /home/node/signalk/node_modules/signalk-server/bin/signalk-server --securityenabled "$@"
