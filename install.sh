#!/usr/bin/env bash
# Install usage-guard into ${PREFIX:-~/.local/bin} and add it to Claude Code's settings.json.
#   curl -fsSL https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/main/install.sh | bash
set -euo pipefail
PREFIX=${PREFIX:-$HOME/.local/bin}
command -v jq >/dev/null || { echo "usage-guard needs jq (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq)" >&2; exit 1; }
mkdir -p "$PREFIX"
src=
[ -n "${BASH_SOURCE[0]:-}" ] && src=$(dirname "${BASH_SOURCE[0]}")/bin/usage-guard
if [ -f "$src" ]; then # running from a clone
  install -m 755 "$src" "$PREFIX/usage-guard"
else
  curl -fsSL "https://raw.githubusercontent.com/ETM-Code/claude-usage-guard/${USAGE_GUARD_REF:-main}/bin/usage-guard" -o "$PREFIX/usage-guard"
  chmod 755 "$PREFIX/usage-guard"
fi
"$PREFIX/usage-guard" install
case ":$PATH:" in *":$PREFIX:"*) ;; *) echo "note: $PREFIX is not on your PATH; add it, or run $PREFIX/usage-guard" ;; esac
