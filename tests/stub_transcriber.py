"""A stand-in for Groq/OpenAI's /audio/transcriptions endpoint, for exercising the
live pipeline (ffmpeg -> VAD -> transcribe -> store) without an API key.

    python tests/stub_transcriber.py            # listens on 127.0.0.1:8099
    GROQ_URL=http://127.0.0.1:8099/v1/audio/transcriptions GROQ_API_KEY=test \\
        python main.py --source tests/fixtures/audio/synthetic_dispatch.wav

Each request is validated against the shape transcribe.py sends (multipart WAV,
model, prompt, response_format=verbose_json, language=en) and answered with a
verbose_json body whose text cycles through a few canned dispatches. The clip's
duration is derived from the WAV so the pipeline sees realistic values.
"""
from __future__ import annotations

import io
import itertools
import json
import sys
import wave

import uvicorn
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile

app = FastAPI()
TEXTS = itertools.cycle([
    "Truck 8, Battalion 1, structure fire, 1621 North 33rd Street, smoke showing second floor.",
    "Baker 12, disturbance, 27th and Vine, the Kwik Shop, two males fighting in the parking lot.",
    "Engine 5 en route.",
    "Lancaster 14, injury accident, Highway 2 and 84th, two vehicles.",
])
seen: list[dict] = []


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(...),
    prompt: str = Form(""),
    response_format: str = Form("json"),
    language: str = Form("en"),
    temperature: str = Form("0"),
    authorization: str | None = Header(None),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer")
    data = await file.read()
    try:
        with wave.open(io.BytesIO(data)) as w:
            duration = w.getnframes() / w.getframerate()
            rate, ch = w.getframerate(), w.getnchannels()
    except wave.Error as e:
        raise HTTPException(400, f"not a WAV: {e}")
    text = next(TEXTS)
    seen.append({"model": model, "prompt_chars": len(prompt), "format": response_format, "language": language,
                 "duration": round(duration, 2), "rate": rate, "channels": ch, "bytes": len(data)})
    print(json.dumps(seen[-1]), flush=True)
    if response_format != "verbose_json":
        return {"text": text}
    return {
        "task": "transcribe", "language": "en", "duration": duration, "text": text,
        "segments": [{"id": 0, "start": 0.0, "end": duration, "text": " " + text,
                      "avg_logprob": -0.25, "no_speech_prob": 0.02, "compression_ratio": 1.2}],
    }


@app.get("/seen")
def get_seen():
    return {"requests": seen}


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
