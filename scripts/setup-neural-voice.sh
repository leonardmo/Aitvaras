#!/bin/zsh
# Install Aitvaras's neural voice (Chatterbox Multilingual + Kokoro) into a
# private venv and pre-download pinned model weights. Idempotent; ~6 GB total.
set -e

VENV="${1:-$HOME/Library/Application Support/Aitvaras/voice-venv}"
PYTHON=""
for candidate in \
    /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 \
    /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 \
    /opt/homebrew/bin/python3.10 /usr/local/bin/python3.10; do
    if [ -x "$candidate" ]; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "Python 3.10–3.12 missing — run: brew install python@3.12" >&2
    exit 1
fi

echo "[setup] creating venv at $VENV"
mkdir -p "$(dirname "$VENV")"
"$PYTHON" -m venv "$VENV"
mkdir -p "$VENV/sandbox-home" "$VENV/hf-cache"
export HOME="$VENV/sandbox-home"
export HF_HOME="$VENV/hf-cache"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONNOUSERSITE=1
"$VENV/bin/pip" install --quiet --upgrade pip
echo "[setup] installing pinned voice engines (torch included, several GB)…"
"$VENV/bin/pip" install --quiet \
    "chatterbox-tts==0.1.7" \
    "mlx-audio==0.4.2"

echo "[setup] pre-downloading model weights…"
"$VENV/bin/python" - <<'EOF'
import torch
device = "mps" if torch.backends.mps.is_available() else "cpu"
import perth
if perth.PerthImplicitWatermarker is None:
    perth.PerthImplicitWatermarker = perth.DummyWatermarker
from mlx_audio.tts.utils import load_model
load_model(
    "prince-canuma/Kokoro-82M",
    revision="e02c9eada7ce7416798af36b190a8a2dd2ecd566",
    token=False,
)
import chatterbox.mtl_tts as chatterbox_mtl
original_snapshot_download = chatterbox_mtl.snapshot_download
def pinned_snapshot_download(*args, **kwargs):
    kwargs["revision"] = "5bb1f6ee58e50c3b8d408bc82a6d3740c2db6e18"
    kwargs["token"] = False
    return original_snapshot_download(*args, **kwargs)
chatterbox_mtl.snapshot_download = pinned_snapshot_download
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
model = ChatterboxMultilingualTTS.from_pretrained(device=device)
print("[setup] model cached, sample rate", model.sr)
EOF

printf '%s\n' 'chatterbox-tts==0.1.7' 'mlx-audio==0.4.2' \
    > "$VENV/.aitvaras-voice-lock"
touch "$VENV/.aitvaras-private-cache-ready"
touch "$VENV/.aitvaras-ready"
echo "[setup] done"
