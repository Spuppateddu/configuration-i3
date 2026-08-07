#!/usr/bin/env bash
# Uniform entry point for orchestrators (e.g. best-linux-environment): they
# clone/update this repo and just call ./install.sh. The real install logic
# lives in setup.sh; this wrapper delegates to it, then live-reloads a running
# i3 session so a pulled config applies immediately.
#
# Usage: ./install.sh [--dry-run]     (also honours DRY_RUN=true from the env)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { printf 'usage: %s [--dry-run]   (or DRY_RUN=true in the env)\n' "${0##*/}" >&2; exit 2; }

# Normalised here and nowhere else; setup.sh takes the flag alone. DRY_RUN=1 is
# the obvious orchestrator spelling, and anything unrecognised is an error.
dry="${DRY_RUN:-false}"
case "${dry,,}" in
    false|0|no|off) DRY_RUN=false ;;
    true|1|yes|on)  DRY_RUN=true ;;
    *) printf '%s: DRY_RUN=%s is not a boolean — use true or false\n' "${0##*/}" "$dry" >&2; exit 2 ;;
esac

case "${1:-}" in
    '')        ;;
    --dry-run) DRY_RUN=true ;;
    *)         usage ;;
esac
[[ $# -le 1 ]] || usage

args=()
[[ "$DRY_RUN" == true ]] && args+=(--dry-run)

bash "$REPO/setup.sh" ${args[@]+"${args[@]}"}

# setup.sh's check passed, so ~/.i3rc resolves here and this spelling is safe.
# It is also required: launch_eww.sh's `pgrep -f "$CFG/scripts/"` sweep matches
# nothing when handed the clone path, and then stacks a second set of listeners.
REPO="$HOME/.i3rc"

if [[ "$DRY_RUN" != true ]] && command -v i3-msg >/dev/null 2>&1 \
   && i3-msg -t get_version >/dev/null 2>&1; then
    i3-msg reload >/dev/null || echo "i3 reload failed — try \$mod+Shift+r." >&2

    # An i3 reload does not re-run exec_always, so it leaves the old bar running.
    # `eww reload` rather than launch_eww.sh, which is a no-op when the bar is
    # already up. Sourced inside the guard: --dry-run must touch nothing.
    # shellcheck source=scripts/eww_lib.sh
    source "$REPO/scripts/eww_lib.sh" || exit 1
    if [[ -x "$EWW" ]] && eww_bar_is_open; then
        "$EWW" --config "$CFG" reload >/dev/null 2>&1 \
            || echo "eww reload failed — try \$mod+Shift+r." >&2
    else
        "$REPO/scripts/launch_eww.sh" || echo "eww bar launch failed — try \$mod+Shift+r." >&2
    fi
fi
