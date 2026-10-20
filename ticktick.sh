#!/bin/bash
# TickTick Open API helper for the pomodoro widget.
#
#   ticktick.sh search <keywords>   matching undone tasks as [{id, projectId, title, project}]
#   ticktick.sh upcoming            undone tasks due in the next two weeks, same shape
#   ticktick.sh focus <json>        log a focus record; queued and retried later if it fails
#   ticktick.sh complete <projectId> <taskId>   mark a task done
#
# The token is read from ~/.config/omarchy/ticktick-token and handed to curl on
# stdin, so it never appears in the process list.

set -uo pipefail

API="https://api.ticktick.com/open/v1"
TOKEN_FILE="$HOME/.config/omarchy/ticktick-token"
QUEUE="$HOME/.local/state/omarchy/pomodoro-ticktick-queue.jsonl"

[[ -r $TOKEN_FILE ]] || { echo "no-token"; exit 2; }
token=$(tr -d '[:space:]' <"$TOKEN_FILE")
[[ -n $token ]] || { echo "no-token"; exit 2; }

# api METHOD PATH [BODY] -> prints the response body, then the HTTP code on its own last line.
api() {
  local args=(-sS --max-time 15 -X "$1" -H @- -w '\n%{http_code}' "$API$2")
  [[ -n ${3:-} ]] && args+=(-H "Content-Type: application/json" --data "$3")
  curl "${args[@]}" <<<"Authorization: Bearer $token"
}

# Project names for labelling tasks, as {id: name}.
projects() {
  local out
  out=$(api GET /project) || { echo '{}'; return; }
  [[ ${out##*$'\n'} == 200 ]] || { echo '{}'; return; }
  sed '$d' <<<"$out" | jq -c 'map({(.id): .name}) | add // {}'
}

# Turn a task array into the slim shape the widget reads.
slim_tasks() {
  local body=$1 names
  names=$(projects)
  jq -c --argjson names "$names" \
    '[.[] | select(.status == 0 or .status == null) | {id, projectId, title, project: ($names[.projectId] // (if .projectId | tostring | startswith("inbox") then "Inbox" else "" end))}] | .[:30]' \
    <<<"$body"
}

post_focus() {
  local out
  out=$(api POST /focus "$1") || return 1
  [[ ${out##*$'\n'} =~ ^20[01]$ ]]
}

flush_queue() {
  [[ -s $QUEUE ]] || return 0
  local remaining=() line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    post_focus "$line" || remaining+=("$line")
  done <"$QUEUE"
  if ((${#remaining[@]})); then printf '%s\n' "${remaining[@]}" >"$QUEUE"; else rm -f "$QUEUE"; fi
}

case "${1:-}" in
search)
  body=$(jq -cn --arg k "${2:-}" '{keywords: $k, status: [0]}')
  out=$(api POST /task/search "$body") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} == 200 ]] || { echo "error"; exit 1; }
  slim_tasks "$(sed '$d' <<<"$out")"
  ;;
upcoming)
  start=$(date +%Y-%m-%dT00:00:00%z)
  end=$(date -d '+13 days' +%Y-%m-%dT23:59:59%z)
  body=$(jq -cn --arg s "$start" --arg e "$end" '{startDate: $s, endDate: $e}')
  out=$(api POST /task/undone "$body") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} == 200 ]] || { echo "error"; exit 1; }
  slim_tasks "$(sed '$d' <<<"$out")"
  ;;
focus)
  record=${2:-}
  jq -e . >/dev/null 2>&1 <<<"$record" || { echo "bad-record"; exit 1; }
  mkdir -p "$(dirname "$QUEUE")"
  flush_queue
  if post_focus "$record"; then
    echo "ok"
  else
    jq -c . <<<"$record" >>"$QUEUE"
    echo "queued"
  fi
  ;;
complete)
  project=${2:-} task=${3:-}
  [[ $project =~ ^[A-Za-z0-9]+$ && $task =~ ^[A-Za-z0-9]+$ ]] || { echo "bad-id"; exit 1; }
  out=$(api POST "/project/$project/task/$task/complete") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} =~ ^20[01]$ ]] || { echo "error"; exit 1; }
  echo "ok"
  ;;
*)
  echo "usage: ticktick.sh search <keywords> | upcoming | focus <json> | complete <projectId> <taskId>" >&2
  exit 1
  ;;
esac
