"""Tiny API + static map. Run: uvicorn server:app --host 0.0.0.0 --port 8000"""
from __future__ import annotations

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import config
import db

app = FastAPI(title="livewire")
db.init()


@app.get("/api/events")
def events(hours: float = Query(2.0, ge=0.1, le=48), mapped: bool = True):
    return {
        "center": config.MAP_CENTER,
        "events": db.recent(hours=hours, mapped_only=mapped),
    }


@app.get("/api/transcript")
def transcript(hours: float = Query(1.0, ge=0.1, le=48)):
    """Everything heard, mapped or not — the scrolling 'what are they saying' feed."""
    return {"events": db.recent(hours=hours, mapped_only=False)}


@app.get("/")
def index():
    return FileResponse(config.ROOT / "static" / "index.html")


app.mount("/audio", StaticFiles(directory=config.AUDIO_DIR), name="audio")
app.mount("/static", StaticFiles(directory=config.ROOT / "static"), name="static")
