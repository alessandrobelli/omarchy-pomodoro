#!/bin/bash
# TickTick Open API helper for the pomodoro widget.
#
# Every request arrives as one line of JSON on stdin, so nothing private
# (search text, task and list ids, focus records) shows up in the process
# list. The command name is the only argument:
#
#   ticktick.sh search     {"keywords": "..."}             matching undone tasks as [{id, projectId, title, project}]
#   ticktick.sh upcoming   (no input)                      undone tasks due in the next two weeks, same shape
#   ticktick.sh focus      {focus record}                  log a focus record: ok, queued (retried with the next
#                                                          one), auth (token refused, kept) or rejected (dropped)
#   ticktick.sh complete   {"projectId": .., "taskId": ..} mark a task done
#
# The token, request bodies and list names likewise reach curl and jq through
# owner-only files in a private temporary directory, never through argv.

set -uo pipefail
umask 077

API="https://api.ticktick.com/open/v1"
TOKEN_FILE="$HOME/.config/omarchy/ticktick-token"
QUEUE="$HOME/.local/state/omarchy/pomodoro-ticktick-queue.jsonl"

[[ -r $TOKEN_FILE ]] || { echo "no-token"; exit 2; }
token=$(tr -d '[:space:]' <"$TOKEN_FILE")
[[ $token =~ ^[A-Za-z0-9._-]+$ ]] || { echo "no-token"; exit 2; }

work=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/pomodoro-ticktick.XXXXXX") || { echo "error"; exit 1; }
trap 'rm -rf "$work"' EXIT

# One line of JSON from the widget; "{}" when there is none.
request="{}"
if [[ ${1:-} != upcoming ]]; then
  IFS= read -r -t 5 request || true
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$request" || request="{}"
fi

# api METHOD PATH [BODY] -> prints the response body, then the HTTP code on its own last line.
# URL, token and body all go through a curl config file, so the command line
# only ever shows that file's path.
api() {
  local config=$work/curl.conf
  {
    printf 'url = "%s%s"\n' "$API" "$2"
    printf 'request = "%s"\n' "$1"
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    if [[ -n ${3:-} ]]; then
      printf '%s' "$3" >"$work/body"
      printf 'header = "Content-Type: application/json"\n'
      printf 'data-binary = "@%s"\n' "$work/body"
    fi
  } >"$config"
  curl -sS --max-time 15 -w '\n%{http_code}' -K "$config"
}

# Project names for labelling tasks, saved as {id: name} in a private file.
save_projects() {
  local out
  out=$(api GET /project) || { echo '{}' >"$work/names"; return; }
  if [[ ${out##*$'\n'} == 200 ]]; then
    sed '$d' <<<"$out" | jq -c 'map({(.id): .name}) | add // {}' >"$work/names" || echo '{}' >"$work/names"
  else
    echo '{}' >"$work/names"
  fi
}

# Turn a task array (stdin) into the slim shape the widget reads.
slim_tasks() {
  save_projects
  jq -c --slurpfile names "$work/names" \
    '($names[0] // {}) as $names
     | [.[] | select(.status == 0 or .status == null)
        | {id, projectId, title,
           project: ($names[.projectId // ""] // (if .projectId | tostring | startswith("inbox") then "Inbox" else "" end))}]
     | .[:30]'
}

# post_focus RECORD -> 0 sent, 1 worth retrying (network, 5xx, rate limit),
# 2 refused for good (the record itself, e.g. a deleted task), 3 token refused.
post_focus() {
  local out code
  out=$(api POST /focus "$1") || return 1
  code=${out##*$'\n'}
  case $code in
  200 | 201) return 0 ;;
  401 | 403) return 3 ;;
  429) return 1 ;;
  4??) return 2 ;;
  *) return 1 ;;
  esac
}

# Sends what's queued. Sets token_refused and stops at the first 401/403,
# keeping the rest; drops records TickTick refuses for good.
token_refused=0
flush_queue() {
  [[ -s $QUEUE ]] || return 0
  local remaining=() line status
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if ((token_refused)); then remaining+=("$line"); continue; fi
    post_focus "$line"
    status=$?
    case $status in
    1) remaining+=("$line") ;;
    3) token_refused=1; remaining+=("$line") ;;
    esac
  done <"$QUEUE"
  # Written aside and moved into place, so a kill mid-write can't truncate the queue.
  if ((${#remaining[@]})); then
    printf '%s\n' "${remaining[@]}" >"$QUEUE.tmp" && mv -f "$QUEUE.tmp" "$QUEUE"
  else
    rm -f "$QUEUE"
  fi
}

case "${1:-}" in
search)
  body=$(jq -c '{keywords: (.keywords // "" | tostring), status: [0]}' <<<"$request")
  out=$(api POST /task/search "$body") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} == 200 ]] || { echo "error"; exit 1; }
  sed '$d' <<<"$out" | slim_tasks
  ;;
upcoming)
  body=$(jq -cn --arg s "$(date +%Y-%m-%dT00:00:00%z)" --arg e "$(date -d '+13 days' +%Y-%m-%dT23:59:59%z)" \
    '{startDate: $s, endDate: $e}')
  out=$(api POST /task/undone "$body") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} == 200 ]] || { echo "error"; exit 1; }
  sed '$d' <<<"$out" | slim_tasks
  ;;
focus)
  record=$(jq -c . <<<"$request")
  [[ $record != "{}" ]] || { echo "bad-record"; exit 1; }
  mkdir -p "$(dirname "$QUEUE")"
  # One sender at a time: two at once would post the same queued records
  # twice, or rewrite the queue over a line the other just added.
  exec 9>>"$QUEUE.lock"
  flock 9
  flush_queue
  if ((token_refused)); then
    printf '%s\n' "$record" >>"$QUEUE"
    echo "auth"
    exit 1
  fi
  post_focus "$record"
  case $? in
  0) echo "ok" ;;
  2) echo "rejected"; exit 1 ;;
  3) printf '%s\n' "$record" >>"$QUEUE"; echo "auth"; exit 1 ;;
  *) printf '%s\n' "$record" >>"$QUEUE"; echo "queued" ;;
  esac
  ;;
complete)
  project=$(jq -r '.projectId // ""' <<<"$request")
  task=$(jq -r '.taskId // ""' <<<"$request")
  [[ $project =~ ^[A-Za-z0-9]+$ && $task =~ ^[A-Za-z0-9]+$ ]] || { echo "bad-id"; exit 1; }
  out=$(api POST "/project/$project/task/$task/complete") || { echo "error"; exit 1; }
  [[ ${out##*$'\n'} =~ ^20[01]$ ]] || { echo "error"; exit 1; }
  echo "ok"
  ;;
*)
  echo "usage: ticktick.sh search|upcoming|focus|complete  (request as one JSON line on stdin)" >&2
  exit 1
  ;;
esac
