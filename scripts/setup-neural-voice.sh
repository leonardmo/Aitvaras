#!/bin/zsh
# Install Aitvaras's neural voice (Chatterbox Multilingual) into a private
# venv and pre-download the model weights. Idempotent; ~6 GB total.
set -e

PYTHON=/opt/homebrew/bin/python3.12
VENV="$HOME/Library/Application Support/Aitvaras/voice-venv"

if [ ! -x "$PYTHON" ]; then
    echo "python3.12 missing — run: brew install python@3.12" >&2
    exit 1
fi

echo "[setup] creating venv at $VENV"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
echo "[setup] installing chatterbox-tts (torch included, several GB)…"
"$VENV/bin/pip" install --quiet chatterbox-tts

echo "[setup] pre-downloading model weights…"
"$VENV/bin/python" - <<'EOF'
import torch
device = "mps" if torch.backends.mps.is_available() else "cpu"
import perth
if perth.PerthImplicitWatermarker is None:
    perth.PerthImplicitWatermarker = perth.DummyWatermarker
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
model = ChatterboxMultilingualTTS.from_pretrained(device=device)
print("[setup] model cached, sample rate", model.sr)
EOF

touch "$VENV/.aitvaras-ready"
echo "[setup] done"
