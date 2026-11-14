#!/usr/bin/env bash
# Suite: the plugin manifest names the plugin and its version.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$root/plugins/factory/.claude-plugin/plugin.json"
[ "$(jq -r .name "$manifest")" = "factory" ] || { echo "plugin name is not factory"; exit 1; }
[ "$(jq -r .version "$manifest")" = "0.0.1" ] || { echo "plugin version is not 0.0.1"; exit 1; }
[ "$(jq -r '.plugins[0].name' "$root/.claude-plugin/marketplace.json")" = "factory" ] || { echo "marketplace does not list factory"; exit 1; }
hooks="$root/plugins/factory/hooks/hooks.json"
wired() { jq -e --arg e "$1" --arg s "$2" '[.hooks[$e][]?.hooks[]?.command | select(endswith($s + "\""))] | length == 1' "$hooks" >/dev/null; }
wired SubagentStart hooks/factory-rules.sh || { echo "factory-rules is not wired to SubagentStart"; exit 1; }
wired SubagentStop hooks/build-clean.sh || { echo "build-clean is not wired to SubagentStop"; exit 1; }
for h in factory-rules build-clean; do
  [ -x "$root/plugins/factory/hooks/$h.sh" ] || { echo "hooks/$h.sh is not executable"; exit 1; }
done
monitors="$root/plugins/factory/monitors/monitors.json"
jq -e '[.[] | select(.name == "factory-watch" and (.command | endswith("bin/factory-watch\"")) and (.when | startswith("on-skill-invoke:")))] | length == 1' "$monitors" >/dev/null || { echo "factory-watch is not registered as a monitor"; exit 1; }
[ -x "$root/plugins/factory/bin/factory-watch" ] || { echo "bin/factory-watch is not executable"; exit 1; }
echo "manifest suite passed"
