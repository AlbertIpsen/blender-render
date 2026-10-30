# Job bookkeeping shared by remote_render.sh and render_status.sh (bash 3.2, sourced).
#
# Every job gets remote/jobs/<id>.log (full Blender output) and remote/jobs/<id>.status, a file of
# KEY='value' lines that render_status.sh reads. Keys: JOB PROJ BLEND SCRIPT ARGS PID STAGE STARTED
# UPDATED ENDED DEVICE FRAME SAMPLE SAMPLES REMAINING SAVED LAST_FILE FETCHED RESULT.

JOBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jobs"

# job_set <status file> KEY value [KEY value ...]: update keys in place (atomic rewrite).
job_set() {
    local f="$1"; shift
    local tmp="$f.tmp.$$"
    [[ -f "$f" ]] && cp "$f" "$tmp" || : > "$tmp"
    while [[ $# -ge 2 ]]; do
        grep -v "^$1=" "$tmp" > "$tmp.2" || :
        printf "%s=%q\n" "$1" "$2" >> "$tmp.2"
        mv "$tmp.2" "$tmp"
        shift 2
    done
    grep -v "^UPDATED=" "$tmp" > "$tmp.2" || :
    printf "UPDATED=%s\n" "$(date +%s)" >> "$tmp.2"
    mv "$tmp.2" "$f"; rm -f "$tmp"
}

# job_track <status file> <log file>: tee Blender output into the log and keep progress current.
# Understands progress.py's "progress: frame=1 sample=32/128 remaining=00:41.20" lines (and Blender
# 4.x's own "Fra:N ... Sample 32/128" lines), Blender's
# "Saved: '<path>'" lines and remote_gpu.py's "remote_gpu: OPTIX [...]" line.
job_track() {
    local st="$1" log="$2" line last=0 now saved=0
    local frame="" sample="" samples="" remaining=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        printf "%s\n" "$line" >> "$log"
        case "$line" in
            *"remote_gpu:"*)
                job_set "$st" DEVICE "${line#*remote_gpu: }"; continue ;;
            *"Saved: '"*)
                saved=$((saved + 1))
                local p; p="$(sed -nE "s/.*Saved: '([^']*)'.*/\1/p" <<< "$line")"
                job_set "$st" SAVED "$saved" LAST_FILE "${p##*/}" SAMPLE "" SAMPLES "" REMAINING ""; continue ;;
        esac
        if [[ "$line" =~ ^progress:\ frame=([0-9]*)\ sample=([0-9]+)/([0-9]+)\ remaining=(.*)$ ]]; then
            frame="${BASH_REMATCH[1]}"; sample="${BASH_REMATCH[2]}"
            samples="${BASH_REMATCH[3]}"; remaining="${BASH_REMATCH[4]}"
        elif [[ "$line" == *Fra:* ]]; then   # Blender 4.x prints its own progress lines
            frame="$(sed -nE 's/.*Fra:([0-9]+).*/\1/p' <<< "$line")"
            if [[ "$line" =~ Sample\ ([0-9]+)/([0-9]+) ]]; then
                sample="${BASH_REMATCH[1]}"; samples="${BASH_REMATCH[2]}"
            fi
            remaining="$(sed -nE 's/.*Remaining:([0-9:.]+).*/\1/p' <<< "$line")"
        else
            continue
        fi
        now=$(date +%s)
        if (( now - last >= 2 )); then   # don't rewrite the status file on every line
            job_set "$st" FRAME "$frame" SAMPLE "$sample" SAMPLES "$samples" REMAINING "$remaining"
            last=$now
        fi
    done
}

# job_notify <title> <message>: macOS notification (silently skipped if osascript is missing).
job_notify() {
    command -v osascript >/dev/null || return 0
    osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\" sound name \"Glass\"" >/dev/null 2>&1 || :
}
