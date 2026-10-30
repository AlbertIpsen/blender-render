#!/usr/bin/env bash
# Render a job on the Windows GPU PC and bring the results back into the project's renders/ folder.
#
#   remote/remote_render.sh [--bg] <project dir> <file.blend> <script.py> [script args...]
#   remote/remote_render.sh --check
#
# Examples:
#   remote/remote_render.sh GeysierFloorRender GeysierFloorRender.blend render.py packshots_grounded --quality final
#   remote/remote_render.sh --bg GeysierWallRender GeysierWallRender.blend hero_stills.py --set closeup --pct 200
#
# Sends the .blend, scripts/, textures/ and deliverables.toml (not renders/), runs Blender there with
# remote_gpu.py and progress.py first, then copies the PC's renders/ for this job back over the local one (same paths
# as a local render), also when the render fails part way. --bg detaches the job so the terminal can
# be closed. Jobs run one at a time (later ones wait in the queue); follow them with
# remote/render_status.sh, and a macOS notification says when each one ends.
# Settings live in remote_render.env next to this script.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/remote_render.env"
source "$HERE/jobs_lib.sh"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 "$WIN_USER@$WIN_HOST")
ROOT_F="${WIN_ROOT//\\//}"

if [[ "${1:-}" == "--check" ]]; then
    "${SSH[@]}" "\"$WIN_BLENDER\" -b --factory-startup --python-expr \"import bpy; p=bpy.context.preferences.addons['cycles'].preferences; p.compute_device_type='OPTIX'; p.refresh_devices(); print('GPU:', [d.name for d in p.devices if d.type=='OPTIX'])\"" \
        | grep -E "^(Blender|GPU:)"
    exit 0
fi

BG=0
[[ "${1:-}" == "--bg" ]] && { BG=1; shift; }
[[ $# -ge 3 ]] || { sed -n '2,16p' "$0"; exit 2; }
PROJ_DIR="$(cd "$1" && pwd)"; BLEND="$2"; SCRIPT="$3"; shift 3
PROJ="$(basename "$PROJ_DIR")"
R="$WIN_ROOT\\$PROJ"          # cmd.exe paths need backslashes
RF="$ROOT_F/$PROJ"            # blender / tar are happy with forward slashes
[[ -f "$PROJ_DIR/$BLEND" ]] || { echo "no $PROJ_DIR/$BLEND"; exit 1; }
[[ -f "$PROJ_DIR/scripts/$SCRIPT" ]] || { echo "no $PROJ_DIR/scripts/$SCRIPT"; exit 1; }

mkdir -p "$JOBS_DIR"
JOB="${JOB:-$(date +%Y%m%d-%H%M%S)_${PROJ}_${SCRIPT%.py}}"
ST="$JOBS_DIR/$JOB.status"; LOG="$JOBS_DIR/$JOB.log"

if (( BG )); then
    JOB="$JOB" nohup "$0" "$PROJ_DIR" "$BLEND" "$SCRIPT" "$@" > /dev/null 2>> "$LOG" &
    echo "job $JOB started in the background"
    echo "  follow it:  remote/render_status.sh -w      log: remote/jobs/$JOB.log"
    exit 0
fi

ARGS=""
for a in "$@"; do ARGS+=" \"$a\""; done
job_set "$ST" JOB "$JOB" PROJ "$PROJ" BLEND "$BLEND" SCRIPT "$SCRIPT" ARGS "${ARGS# }" PID $$ \
    STAGE queued STARTED "$(date +%s)"
say() { echo "$*"; echo "$*" >> "$LOG"; }

finish() {
    local rc=$?
    rm -rf "$JOBS_DIR/.gpu.lock/$$" 2>/dev/null; rmdir "$JOBS_DIR/.gpu.lock" 2>/dev/null || :
    grep -q "^RESULT=" "$ST" 2>/dev/null && return
    job_set "$ST" STAGE failed RESULT failed ENDED "$(date +%s)"
    job_notify "Render failed: $PROJ" "$SCRIPT stopped (exit $rc) - see remote/jobs/$JOB.log"
}
trap finish EXIT
# Keep the Mac awake until this job ends; a sleeping Mac drops the SSH session and the fetch.
command -v caffeinate >/dev/null && { caffeinate -i -w $$ & }

# One job on the GPU at a time: wait for the lock (a dead holder's lock is taken over).
while ! mkdir "$JOBS_DIR/.gpu.lock" 2>/dev/null; do
    sleep 5
    holder="$(ls "$JOBS_DIR/.gpu.lock" 2>/dev/null | head -1)"
    [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null && rm -rf "$JOBS_DIR/.gpu.lock"
done
mkdir "$JOBS_DIR/.gpu.lock/$$"

t0=$(date +%s)
job_set "$ST" STAGE sending
say "== $PROJ: sending to $WIN_HOST"
"${SSH[@]}" "if not exist \"$R\" mkdir \"$R\"& if exist \"$R\\renders\" rmdir /s /q \"$R\\renders\""
files=("$BLEND" scripts)
for f in textures deliverables.toml; do [[ -e "$PROJ_DIR/$f" ]] && files+=("$f"); done
COPYFILE_DISABLE=1 tar -cf - --exclude __pycache__ --exclude '.DS_Store' -C "$PROJ_DIR" "${files[@]}" -C "$HERE" remote_gpu.py progress.py \
    | "${SSH[@]}" "tar -xf - -C \"$RF\""

job_set "$ST" STAGE rendering
say "== rendering: $SCRIPT$ARGS"
set +e
"${SSH[@]}" "cd /d \"$R\" && \"$WIN_BLENDER\" -b \"$RF/$BLEND\" --python-exit-code 1 -P \"$RF/remote_gpu.py\" -P \"$RF/progress.py\" -P \"$RF/scripts/$SCRIPT\" --$ARGS" 2>&1 \
    | job_track "$ST" "$LOG"
render_rc=${PIPESTATUS[0]}
set -e
grep -E "^(remote_gpu:|Error|Traceback)|Saved: '" "$LOG" | tail -40 || :

job_set "$ST" STAGE fetching
say "== fetching renders"
tmp="$(mktemp -t remote_render).tar"
"${SSH[@]}" "if exist \"$R\\renders\" tar -cf - -C \"$RF\" renders" > "$tmp"
fetched=0
if [[ -s "$tmp" ]]; then
    tar -xf "$tmp" -C "$PROJ_DIR"
    tar -tf "$tmp" | grep -vE '/$' | sed "s|^|  $PROJ/|" | tee -a "$LOG"
    fetched=$(tar -tf "$tmp" | grep -vcE '/$' || :)
else
    say "  (no renders/ written)"
fi
rm -f "$tmp"

took="$(( ($(date +%s) - t0) / 60 )) min $(( ($(date +%s) - t0) % 60 )) s"
if (( render_rc == 0 )); then
    job_set "$ST" STAGE done RESULT ok ENDED "$(date +%s)" FETCHED "$fetched"
    job_notify "Render done: $PROJ" "$SCRIPT - $fetched file(s) back in $PROJ/renders ($took)"
    say "== done in $took"
else
    job_set "$ST" STAGE failed RESULT failed ENDED "$(date +%s)" FETCHED "$fetched"
    job_notify "Render failed: $PROJ" "$SCRIPT exited $render_rc after $took; $fetched file(s) fetched"
    say "== render failed (exit $render_rc) after $took; log: remote/jobs/$JOB.log"
    exit "$render_rc"
fi
