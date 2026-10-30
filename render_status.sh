#!/usr/bin/env bash
# Show the remote render jobs started from this Mac (newest first).
#
#   remote/render_status.sh            jobs and their progress
#   remote/render_status.sh -w         same, refreshing every 2 s until Ctrl-C
#   remote/render_status.sh -l [job]   follow a job's Blender log (default: newest job)
#   remote/render_status.sh -o [job]   open the job's renders/ folder in Finder
#   remote/render_status.sh -n 20      show the last 20 jobs (default 8)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/jobs_lib.sh"
BLENDER_DIR="$(dirname "$HERE")"
N=8

newest() { ls -t "$JOBS_DIR"/*.status 2>/dev/null | head -1 | sed 's|.*/||; s|\.status$||'; }
pick() { local j="${1:-$(newest)}"; [[ -n "$j" && -f "$JOBS_DIR/$j.status" ]] || { echo "no such job: ${1:-}" >&2; exit 1; }; echo "$j"; }
dur() { local s=$1; (( s >= 3600 )) && printf "%dh%02dm" $((s/3600)) $((s%3600/60)) || printf "%dm%02ds" $((s/60)) $((s%60)); }

bar() {   # bar <done> <total> <width>
    local d=$1 t=$2 w=$3 n i out=""
    (( t > 0 )) || { printf "%${w}s" ""; return; }
    n=$(( d * w / t ))
    for ((i = 0; i < w; i++)); do (( i < n )) && out+="#" || out+="."; done
    printf "%s %3d%%" "$out" $(( d * 100 / t ))
}

show() {
    local files f now
    files=$(ls -t "$JOBS_DIR"/*.status 2>/dev/null | head -"$N")
    [[ -n "$files" ]] || { echo "No render jobs yet. Start one with remote/remote_render.sh --bg ..."; return; }
    now=$(date +%s)
    for f in $files; do
        (
            JOB="" PROJ="" SCRIPT="" ARGS="" PID="" STAGE="" STARTED=$now UPDATED=$now ENDED="" DEVICE=""
            FRAME="" SAMPLE="" SAMPLES="" REMAINING="" SAVED=0 LAST_FILE="" FETCHED="" RESULT=""
            source "$f"
            # A job still marked active whose process is gone was killed (Mac slept, terminal closed...).
            if [[ -z "$RESULT" && -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then STAGE="lost"; fi
            case "$STAGE" in
                done) icon="✓" ;; failed|lost) icon="✗" ;; queued) icon="…" ;; *) icon="▶" ;;
            esac
            end=${ENDED:-$now}
            printf "%s %-10s %-52s %s\n" "$icon" "$STAGE" "$JOB" "$(dur $((end - STARTED)))"
            printf "    %s %s  %s\n" "$SCRIPT" "$ARGS" "${DEVICE:+[$DEVICE]}"
            case "$STAGE" in
                rendering)
                    line="    stills saved: ${SAVED:-0}"
                    [[ -n "$SAMPLES" ]] && line+="   current: $(bar "${SAMPLE:-0}" "$SAMPLES" 24) (${SAMPLE}/${SAMPLES} samples, frame ${FRAME})"
                    [[ -n "$REMAINING" ]] && line+="   ~${REMAINING} left on this one"
                    echo "$line"
                    [[ -n "$LAST_FILE" ]] && echo "    last saved: $LAST_FILE"
                    (( now - UPDATED > 300 )) && echo "    (no output for $(dur $((now - UPDATED))) - check the log with -l)"
                    ;;
                done)   echo "    ${FETCHED:-0} file(s) back in $PROJ/renders/" ;;
                failed) echo "    ${FETCHED:-0} file(s) fetched; log: remote/jobs/$JOB.log" ;;
                lost)   echo "    the job's process on this Mac is gone; log: remote/jobs/$JOB.log" ;;
            esac
        )
    done
}

case "${1:-}" in
    -w) while :; do out="$(show)"; clear; date "+Remote renders  %H:%M:%S  (Ctrl-C to stop)"; echo; echo "$out"; sleep 2; done ;;
    -l) j=$(pick "${2:-}") || exit 1; exec tail -n 40 -f "$JOBS_DIR/$j.log" ;;
    -o) j=$(pick "${2:-}") || exit 1; source "$JOBS_DIR/$j.status"; open "$BLENDER_DIR/$PROJ/renders" ;;
    -n) N="${2:-8}"; show ;;
    -h|--help) sed -n '2,8p' "$0" ;;
    *) show ;;
esac
