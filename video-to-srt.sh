#!/data/data/com.termux/files/usr/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $(basename "$0") <video_file>"
  exit 1
fi

VIDEO="$1"

if [ ! -f "$VIDEO" ]; then
  echo "Error: file not found: $VIDEO"
  exit 1
fi

DIR="$(dirname "$VIDEO")"
BASE="$(basename "${VIDEO%.*}")"
WAV="$(mktemp "${TMPDIR:-/tmp}/whisper_XXXXXX.wav")"
WAV_NAME="$(basename "$WAV")"

echo "Extracting audio..."
ffmpeg -i "$VIDEO" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$WAV" -y -loglevel error

transcribe_remote() {
  echo "Transcribing on $WHISPER_HOST..."
  local SSH_OPTS="-p $WHISPER_HOST_PORT -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=10"
  local REMOTE_WAV="/tmp/$WAV_NAME"
  local REMOTE_SRT="/tmp/${WAV_NAME%.*}.srt"
  local FW_SCRIPT
  FW_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/fw_XXXXXX.py")"
  local REMOTE_FW_SCRIPT="/tmp/$(basename "$FW_SCRIPT")"

  cat > "$FW_SCRIPT" << 'PYEOF'
import sys, os
from faster_whisper import WhisperModel
wav, model_name, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
model = WhisperModel(model_name, device="cpu", compute_type="int8", cpu_threads=os.cpu_count())
segments, _ = model.transcribe(wav, beam_size=5)
base = os.path.splitext(os.path.basename(wav))[0]
def ts(s):
    h, m = int(s // 3600), int((s % 3600) // 60)
    return f"{h:02d}:{m:02d}:{int(s % 60):02d},{int((s % 1) * 1000):03d}"
with open(os.path.join(out_dir, base + ".srt"), "w") as f:
    for i, seg in enumerate(segments, 1):
        f.write(f"{i}\n{ts(seg.start)} --> {ts(seg.end)}\n{seg.text.strip()}\n\n")
PYEOF

  ssh $SSH_OPTS "$WHISPER_HOST_USER@$WHISPER_HOST" "cat > '$REMOTE_WAV'" < "$WAV" || { rm -f "$FW_SCRIPT"; return 1; }
  ssh $SSH_OPTS "$WHISPER_HOST_USER@$WHISPER_HOST" "cat > '$REMOTE_FW_SCRIPT'" < "$FW_SCRIPT" || { rm -f "$FW_SCRIPT"; return 1; }
  rm -f "$FW_SCRIPT"

  ssh $SSH_OPTS "$WHISPER_HOST_USER@$WHISPER_HOST" "
    MODEL=${WHISPER_MODEL:-base}
    if command -v faster-whisper &>/dev/null; then
      faster-whisper '$REMOTE_WAV' --model \$MODEL --output_format srt --output_dir /tmp \
        && rm -f '$REMOTE_WAV' '$REMOTE_FW_SCRIPT'
    else
      uv run --with faster-whisper python '$REMOTE_FW_SCRIPT' '$REMOTE_WAV' \$MODEL /tmp \
        && rm -f '$REMOTE_WAV' '$REMOTE_FW_SCRIPT'
    fi
  " || return 1

  ssh $SSH_OPTS "$WHISPER_HOST_USER@$WHISPER_HOST" "cat '$REMOTE_SRT'" > "$DIR/$BASE.srt" || return 1

  ssh $SSH_OPTS "$WHISPER_HOST_USER@$WHISPER_HOST" "rm -f '$REMOTE_SRT'" || true
}

transcribe_local() {
  echo "Transcribing locally..."
  whisper "$WAV" --model ${WHISPER_MODEL:-base} --output_format srt --output_dir "$DIR"
  mv "$DIR/${WAV_NAME%.*}.srt" "$DIR/$BASE.srt"
}

if [ -n "$WHISPER_HOST" ] && [ -n "$WHISPER_HOST_PORT" ] && [ -n "$WHISPER_HOST_USER" ]; then
  transcribe_remote || {
    echo "Remote transcription failed."
    read -r -p "Fall back to local transcription? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    transcribe_local
  }
else
  transcribe_local
fi

rm "$WAV"
echo "Saved: $DIR/$BASE.srt"
