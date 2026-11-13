#!/usr/bin/env bash
# Suite: the plugin manifest names the plugin and its version.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$root/plugins/factory/.claude-plugin/plugin.json"
[ "$(jq -r .name "$manifest")" = "factory" ] || { echo "plugin name is not factory"; exit 1; }
[ "$(jq -r .version "$manifest")" = "0.0.1" ] || { echo "plugin version is not 0.0.1"; exit 1; }
[ "$(jq -r '.plugins[0].name' "$root/.claude-plugin/marketplace.json")" = "factory" ] || { echo "marketplace does not list factory"; exit 1; }
echo "manifest suite passed"
