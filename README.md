# Whisper on Android (Termux) — Full Setup Guide

A guide to transcribing video files to SRT subtitles from Android — primarily by offloading to faster-whisper on a remote host via SSH, with openai-whisper on Termux as a last-resort local fallback.

> This guide was produced with [Claude Code](https://claude.ai/code) (Anthropic's CLI). Everything was done on a budget Android phone — no dev machine involved.

> Running whisper on Android is not practical — it's slow, uses all available CPU for hours on a 40-minute episode, and Android will likely kill the process before it finishes. This guide exists purely to demonstrate that it *can* be done. For *real* use (still just for fun 😉), the `video-to-srt.sh` script prefers to offload transcription to a remote host and only falls back to running locally as a last resort.

---

## TL;DR

### Install

```bash
termux-setup-storage
pkg update -y
pkg install -y git ffmpeg cmake ninja rust python-torch python-llvmlite
pip install setuptools-rust
pip install openai-whisper --no-build-isolation
```

### Convert video to SRT

```bash
~/video-to-srt.sh /path/to/video.mp4
```

---

## 1. Initial Termux Setup

### Grant Storage Access

```bash
termux-setup-storage
```

Accept the permission prompt. This creates `~/storage/` with symlinks to your Android storage:

- `~/storage/downloads` → Internal Downloads folder
- `~/storage/shared` → Internal storage root

### Update Package Lists

```bash
pkg update && pkg upgrade -y
```

---

## 2. Install System Tools

### Claude Code

Claude Code is Anthropic's CLI for interacting with Claude. Install via npm:

```bash
pkg install -y nodejs
npm install -g @anthropic-ai/claude-code
```

Then run `claude` and follow the login prompt.

### git

```bash
pkg install -y git
```

### ffmpeg

```bash
pkg install -y ffmpeg
```

Verify:

```bash
ffmpeg -version
```

---

## 3. Install openai-whisper

The `video-to-srt.sh` script uses two versions of whisper depending on context:

- **faster-whisper** — used for remote transcription. It runs on a remote host via `uv run --with faster-whisper`, so nothing needs to be installed there. It is 2-4x faster than openai-whisper on CPU and supports GPU acceleration.
- **openai-whisper** — installed here on Android, used only as a last-resort fallback if remote transcription fails or no remote host is configured.

This section installs openai-whisper locally on Termux. It has several dependencies that don't install cleanly on Android out of the box. Follow each step in order.

### 3.1 Install cmake and ninja (required to build Python packages)

The `cmake` Python package (a build dependency for several packages) tries to compile cmake from source and fails on Android because it can't find `LIBMD_LIBRARY`. The fix is to install system cmake and ninja first so the Python packages wrap them instead.

```bash
pkg install -y cmake ninja
```

### 3.2 Install Rust (required to build tiktoken)

`tiktoken` (whisper's tokenizer) is a Rust extension that must be compiled from source on Android.

```bash
pkg install -y rust
```

### 3.3 Install PyTorch

PyTorch has no pip wheel for Android/ARM64. Termux ships a pre-built package:

```bash
pkg install python-torch
```

This also installs `setuptools 81`, which is important — setuptools 82+ removed `pkg_resources`, breaking older packages that depend on it.

### 3.4 Install llvmlite (required by numba)

`numba` (used by whisper for performance) depends on `llvmlite`, which must be compiled against LLVM. The llvmlite source explicitly rejects `sys.platform == 'android'` and building against the system LLVM also fails due to missing static libraries. Termux ships a pre-built package that bypasses both issues:

```bash
pkg install python-llvmlite
```

### 3.5 Install setuptools-rust

Required for tiktoken's build system:

```bash
pip install setuptools-rust
```

### 3.6 Install openai-whisper

Use `--no-build-isolation` so pip uses the system-installed packages (torch, llvmlite, setuptools/pkg_resources, Rust toolchain) rather than creating an isolated build environment that lacks them.

```bash
pip install openai-whisper --no-build-isolation
```

This will build and install:
- `openai-whisper 20250625`
- `numba` (compiled against the pre-installed llvmlite)
- `tiktoken` (compiled with Rust)
- `regex` (C extension)
- `tqdm`, `more-itertools`, `requests`, and other pure-Python deps

### 3.7 Verify

```bash
python3 -c "import whisper; print(whisper.__version__)"
```

Expected output: `20250625`

---

## 4. Extract Audio from a Video File

Whisper requires audio input. Extract 16kHz mono WAV from any video:

```bash
ffmpeg -i /path/to/video.mp4 \
  -vn -acodec pcm_s16le -ar 16000 -ac 1 \
  /path/to/audio.wav
```

Flags:
- `-vn` — no video
- `-acodec pcm_s16le` — uncompressed PCM (best whisper input quality)
- `-ar 16000` — 16kHz sample rate (whisper's native rate)
- `-ac 1` — mono

---

## 5. Transcribe to SRT (Local)

Uses the locally installed openai-whisper. Last-resort fallback only — slow on Android (see section 3).

```bash
whisper "$TMPDIR/audio.wav" \
  --model base \
  --output_format srt \
  --output_dir /path/to/output/
```

### One-liner (extract + transcribe)

```bash
VIDEO="/path/to/video.mp4"
OUT="/path/to/output"

ffmpeg -i "$VIDEO" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$TMPDIR/audio.wav" && \
whisper "$TMPDIR/audio.wav" --model base --output_format srt --output_dir "$OUT" && \
rm "$TMPDIR/audio.wav"
```

The output SRT will be named after the input audio file (e.g. `audio.srt`). Rename it to match your video file for your media player to pick it up automatically.

---

## 6. Transcribe to SRT (Remote)

Uses faster-whisper on a remote host via SSH. The remote only needs SSH access and `uv` — no whisper packages pre-installed.

```bash
export WHISPER_HOST=your.host.com
export WHISPER_HOST_PORT=22
export WHISPER_HOST_USER=youruser
export WHISPER_MODEL=base  # tiny, base, small, medium, large
```

Use `video-to-srt.sh` (section 7) which handles the full pipeline automatically — audio extraction, upload via SSH, remote transcription, and SRT retrieval.

### Model sizes

| Model | Size | faster-whisper (CPU) | openai-whisper (CPU) | Accuracy |
|---|---|---|---|---|
| `tiny` | 75 MB | ~4x realtime | ~10x realtime | Low |
| `base` | 145 MB | ~3x realtime | ~7x realtime | OK |
| `small` | 461 MB | ~1x realtime | ~2x realtime | Good |
| `medium` | 1.5 GB | ~0.25x realtime | ~0.5x realtime | Better |
| `large` | 2.9 GB | ~0.1x realtime | ~0.2x realtime | Best |

Models are downloaded automatically on first use and cached at `~/.cache/huggingface/` on the remote host.

---

## 7. video-to-srt Script

Clone the repo and run `video-to-srt.sh` directly. If `$WHISPER_HOST`, `$WHISPER_HOST_PORT`, and `$WHISPER_HOST_USER` are all set, the script will upload the audio to that host via SSH, run whisper remotely, and retrieve the SRT — falling back to local transcription if anything fails.

The remote host only needs SSH access and `uv` available — no pre-installed whisper packages required. The script uses `uv run --with faster-whisper` (2-4x faster than openai-whisper on CPU, supports GPU acceleration). If `faster-whisper` is available as a CLI in PATH it will be used directly, skipping uv entirely.

```bash
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
```

Usage:

```bash
~/video-to-srt.sh /path/to/video.mp4
# Outputs: /path/to/video.srt

# With remote host (add these to ~/.bashrc for persistent config):
export WHISPER_HOST=your.host.com
export WHISPER_HOST_PORT=22
export WHISPER_HOST_USER=youruser
export WHISPER_MODEL=base  # tiny, base, small, medium, large
~/video-to-srt.sh /path/to/video.mp4
```

---

## 8. Full Install Script

```bash
#!/data/data/com.termux/files/usr/bin/bash
set -e

# Storage
termux-setup-storage

# System packages
pkg update -y
pkg install -y git ffmpeg cmake ninja rust python-torch python-llvmlite

# Python packages
pip install setuptools-rust
pip install openai-whisper --no-build-isolation

echo "Done. Test with: python3 -c \"import whisper; print(whisper.__version__)\""
```
