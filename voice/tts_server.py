#!/usr/bin/env python3
"""Aitvaras neural TTS sidecar (D3) — dual engine, routed by language.

- English → Kokoro-82M via MLX (near-instant on Apple Silicon)
- German (and other languages) → Chatterbox Multilingual (PyTorch/MPS,
  slower but the only high-quality local option for German)

  GET  /health                      -> {"ok": true, engines...}
  POST /tts {text, language, engine?} -> WAV bytes
"""
import argparse
import io
import json
import struct
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=8756)
args = parser.parse_args()


def log(*items):
    print("[tts]", *items, flush=True)


# --- Kokoro (MLX) — loads in a couple of seconds, do it up front -------
log("loading Kokoro (MLX)…")
import os  # noqa: E402
import sys  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import kokoro_patches  # noqa: E402
from mlx_audio.tts.utils import load_model  # noqa: E402

kokoro_patches.apply()

KOKORO = load_model("prince-canuma/Kokoro-82M")
KOKORO_SR = 24000
KOKORO_VOICE = "af_heart"
log("kokoro ready")

# --- Chatterbox (PyTorch/MPS) — heavy; load in the background ----------
CHATTERBOX = None
CHATTERBOX_ERROR = None


def load_chatterbox():
    global CHATTERBOX, CHATTERBOX_ERROR
    try:
        log("loading Chatterbox Multilingual…")
        import torch
        import perth

        # perth's native watermarker fails to import on some setups,
        # leaving the symbol None and crashing Chatterbox init.
        if perth.PerthImplicitWatermarker is None:
            perth.PerthImplicitWatermarker = perth.DummyWatermarker
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        CHATTERBOX = ChatterboxMultilingualTTS.from_pretrained(device=device)
        log("chatterbox ready on", device)
    except Exception as exc:  # noqa: BLE001
        CHATTERBOX_ERROR = str(exc)
        log("chatterbox failed:", exc)


threading.Thread(target=load_chatterbox, daemon=True).start()

GENERATE_LOCK = threading.Lock()


def wav_bytes(samples: "np.ndarray", sample_rate: int) -> bytes:
    """float32 mono → 16-bit PCM WAV."""
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767).astype("<i2").tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(pcm))
    return header + pcm


def synthesize(text: str, language: str, engine: str) -> bytes:
    with GENERATE_LOCK:
        if engine == "kokoro":
            segments = KOKORO.generate(
                text=text, voice=KOKORO_VOICE, speed=1.0, lang_code="a")
            audio = np.concatenate([np.array(seg.audio) for seg in segments])
            return wav_bytes(audio, KOKORO_SR)

        if CHATTERBOX is None:
            raise RuntimeError(CHATTERBOX_ERROR or "chatterbox still loading")
        import torch

        with torch.inference_mode():
            wav = CHATTERBOX.generate(text, language_id=language)
        return wav_bytes(wav.cpu().numpy().flatten(), CHATTERBOX.sr)


def pick_engine(language: str, requested: str | None) -> str:
    if requested in ("kokoro", "chatterbox"):
        return requested
    return "kokoro" if language == "en" else "chatterbox"


from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer  # noqa: E402


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _reply(self, code, body, content_type="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, json.dumps({
                "ok": True,
                "version": 2,
                "kokoro": True,
                "chatterbox": CHATTERBOX is not None,
                "chatterboxError": CHATTERBOX_ERROR,
            }).encode())
        else:
            self._reply(404, b"{}")

    def do_POST(self):
        if self.path != "/tts":
            self._reply(404, b"{}")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            request = json.loads(self.rfile.read(length))
            text = request.get("text", "").strip()
            language = request.get("language", "en")[:2]
            if not text:
                self._reply(400, b'{"error": "empty text"}')
                return
            engine = pick_engine(language, request.get("engine"))
            # Kokoro fallback if Chatterbox isn't up yet (English quality
            # from Kokoro beats waiting; for German the caller falls back
            # to Apple voices on error).
            if engine == "chatterbox" and CHATTERBOX is None and language == "en":
                engine = "kokoro"
            data = synthesize(text, language, engine)
            self._reply(200, data, content_type="audio/wav")
        except Exception as exc:  # noqa: BLE001 — surfaced to the app
            log("error:", exc)
            self._reply(500, json.dumps({"error": str(exc)}).encode())


# Threading so /health answers while a generation runs (GENERATE_LOCK
# still serializes actual synthesis).
log("serving on port", args.port)
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
