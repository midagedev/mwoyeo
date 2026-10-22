#!/bin/bash
# Film 3's Accessibility steps for the UI take: attribute reads and AXPress / AXValue / AXPosition writes through System Events (no CGEvent, no mouse or keyboard synthesis).
#   ax.sh dump  <pid>                      every element of every window: role | title | description | value | actions
#   ax.sh action <pid> <text> <action>     perform the custom action whose name contains <action> on the first element whose title/description contains <text>   (the lens: "렌즈 메뉴 열기")
#   ax.sh press <pid> <text>               AXPress on the first element (any window, menus included) whose title, description or value contains <text>
#   ax.sh set   <pid> <text> <file>        set AXValue of the first text area/field whose title/description contains <text> to the contents of <file>
#   ax.sh move  <pid> <text> <x> <y>       set the position (points) of the first window whose title contains <text> ("=text": equals it)
#   ax.sh scroll <pid> <window text> <AXScrollDownByPage|AXScrollUpByPage> <n>   perform the page-scroll action <n> times on the window's largest scroll area
#   ax.sh bar <pid> <window text> <0..1>   set the vertical scroll bar value of the window's largest scroll area (AXValue; "=text": exact window name)
#   ax.sh pressafter <pid> <text> <role>   AXPress the first element of <role> (e.g. AXButton) that follows the first non-text element containing <text>
#   ax.sh type  <pid> <text> <file> <chunk> <pause s>   like set, but in prefixes of <chunk> characters every <pause> s (typed look: AXValue writes, no key events)
#   ax.sh presslast <pid> <window text> <role>   AXPress the last element of <role> in the window (the sheet's Done button is the last AXButton)
#   ax.sh wait  <pid> <text> <seconds>     poll until an element with <text> exists (0.5 s steps), exit 1 when not
# FAILURE MODE IT BLOCKS: a step that does nothing and goes unnoticed: every subcommand prints what it touched and exits 1 when it found nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); cmd=${1:-}; pid=${2:-}; [ -n "$pid" ] || { sed -n '2,15p' "$0" >&2; exit 2; }
case $cmd in
dump) exec osascript "$HERE/ax.applescript" dump "$pid" ;;
action) exec osascript "$HERE/ax.applescript" action "$pid" "${3:?text}" "${4:?action}" ;;
press) exec osascript "$HERE/ax.applescript" press "$pid" "${3:?text}" ;;
set) exec osascript "$HERE/ax.applescript" set "$pid" "${3:?text}" "$(cat "${4:?file}")" ;;
move) exec osascript "$HERE/ax.applescript" move "$pid" "${3:?text}" "${4:?x}" "${5:?y}" ;;
scroll) exec osascript "$HERE/ax.applescript" scroll "$pid" "${3:?window text}" "${4:?action}" "${5:?times}" ;;
bar) exec osascript "$HERE/ax.applescript" bar "$pid" "${3:?window text}" "${4:?value}" ;;
pressafter) exec osascript "$HERE/ax.applescript" pressafter "$pid" "${3:?text}" "${4:?role}" ;;
type) exec osascript "$HERE/ax.applescript" type "$pid" "${3:?text}" "$(cat "${4:?file}")" "${5:?chunk}" "${6:?pause}" ;;
presslast) exec osascript "$HERE/ax.applescript" presslast "$pid" "${3:?window text}" "${4:?role}" ;;
wait) end=$((SECONDS + ${4:?seconds})); while [ $SECONDS -lt $end ]; do
          "$0" dump "$pid" 2> /dev/null | grep -qF -- "${3:?text}" && { echo "found $3"; exit 0; }; sleep 0.5; done; echo "ax: no element with $3 in ${4}s" >&2; exit 1 ;;
*) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
