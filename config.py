"""Central configuration. Everything can be overridden with environment variables.

The city config (`cities/<id>.json`, selected by CITY) supplies the bounding
box, map centre, time zone, agencies, vocabulary file and extraction hints.
"""
import json
import os
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).parent
DATA_DIR = Path(os.environ.get("DATA_DIR", ROOT / "data"))   # override for tests / alternate installs
DATA_DIR.mkdir(parents=True, exist_ok=True)
VERSION = "1.0.0"

# --- City -------------------------------------------------------------------
CITIES_DIR = ROOT / "cities"
CITY = os.environ.get("CITY", "lincoln")


def load_city(city_id: str) -> dict:
    return json.loads((CITIES_DIR / f"{city_id}.json").read_text())


def all_cities() -> list[dict]:
    return sorted((json.loads(p.read_text()) for p in CITIES_DIR.glob("*.json")), key=lambda c: c["id"])


_city = load_city(CITY)
CITY_ID: str = _city["id"]
CITY_NAME: str = _city["name"]
CITY_TZ = ZoneInfo(_city["tz"])                 # spoken clock times are local time
BBOX = tuple(_city["bbox"])                      # (west, south, east, north)
LINCOLN_BBOX = BBOX                              # legacy name, kept for older imports
MAP_CENTER = tuple(_city["center"])              # (lat, lon)
AGENCIES: dict = _city["agencies"]               # {"police": {"name": ..., "delayed": bool}, ...}
EXTRACT_HINTS: str = _city.get("extract_hints", "")
VOCAB_FILE = ROOT / _city.get("vocab_file", f"{CITY_ID}_vocab.txt")

# --- Audio source -----------------------------------------------------------
# Broadcastify feed 14395 = "Lincoln Police and Fire, Lancaster County Sheriff"
# (official city feed, linked from lincoln.ne.gov). The raw stream URL requires
# a Broadcastify Premium account; put it in STREAM_URL. Any ffmpeg-readable
# source works here — an HTTP stream, an RTL-SDR via trunk-recorder, a local
# file for testing (see tests/).
STREAM_URL = os.environ.get(_city.get("stream_url_env", "STREAM_URL"), "")
STREAM_HEADERS = os.environ.get("STREAM_HEADERS", "")  # e.g. "Cookie: ...\r\n"

# --- Transcription ----------------------------------------------------------
TRANSCRIBER = os.environ.get("TRANSCRIBER", "groq")           # local | groq | openai
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_URL = os.environ.get("GROQ_URL", "https://api.groq.com/openai/v1/audio/transcriptions")
GROQ_MODEL = os.environ.get("GROQ_MODEL", "whisper-large-v3-turbo")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_URL = os.environ.get("OPENAI_URL", "https://api.openai.com/v1/audio/transcriptions")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "whisper-1")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "small.en")   # local: tiny/base/small/medium/large-v3
WHISPER_DEVICE = os.environ.get("WHISPER_DEVICE", "cpu")      # "cuda" if you have a GPU
WHISPER_COMPUTE = os.environ.get("WHISPER_COMPUTE", "int8")   # int8 on CPU, float16 on GPU

# --- Voice activity detection ---------------------------------------------
SAMPLE_RATE = 16000
MIN_SEGMENT_SEC = 0.8     # drop clicks/squelch tails shorter than this
MAX_SEGMENT_SEC = 30.0    # force-cut long runs so transcription stays responsive
SILENCE_SEC = 1.2         # gap that ends a transmission
# Energy-gate fallback (used when torch/Silero is not installed, i.e. on the VPS):
ENERGY_GATE_THRESHOLD = float(os.environ.get("ENERGY_GATE_THRESHOLD", "0.015"))  # RMS of a 32 ms frame
ENERGY_HANGOVER_MS = int(os.environ.get("ENERGY_HANGOVER_MS", "300"))            # keep "speech" this long after it drops

# --- Extraction -------------------------------------------------------------
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
EXTRACT_MODEL = os.environ.get("EXTRACT_MODEL", "claude-haiku-4-5-20251001")
# Transcripts shorter than this are almost always unit acknowledgements ("10-4")
MIN_TRANSCRIPT_CHARS = 20

# --- Geocoding --------------------------------------------------------------
GEOCODER = os.environ.get("GEOCODER", "nominatim")   # nominatim | mapbox
MAPBOX_TOKEN = os.environ.get("MAPBOX_TOKEN", "")
NOMINATIM_USER_AGENT = f"livewire-{CITY_ID} (personal project)"
NOMINATIM_MIN_INTERVAL = 1.1   # their usage policy: max 1 req/sec

# --- Delay handling ---------------------------------------------------------
# LPD publishes its police audio on a variable, undisclosed delay. Fire/EMS and
# Sheriff on the same feed are live. We estimate the police delay from
# dispatchers reading the clock on air (see delay.py) and back-date events.
DEFAULT_POLICE_DELAY_SEC = int(os.environ.get("DEFAULT_POLICE_DELAY_SEC", "900"))

# --- Incident grouping (DESIGN.md A4) ---------------------------------------
INCIDENT_JOIN_M = 150.0        # a mapped transmission within this joins an active incident
INCIDENT_CLEAR_SEC = 1800      # active -> cleared after this long with no transmissions

# --- API --------------------------------------------------------------------
# Single shared secret; every /api/* and /audio/* request must carry
# "Authorization: Bearer <API_TOKEN>". Unset => "dev-token" (server logs a warning).
API_TOKEN = os.environ.get("API_TOKEN", "")
API_TOKEN_IS_DEFAULT = not API_TOKEN
if API_TOKEN_IS_DEFAULT:
    API_TOKEN = "dev-token"

# --- Push notifications (APNs token auth; DESIGN.md B2.6) -------------------
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "")
APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "")
APNS_BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "")
APNS_SANDBOX = os.environ.get("APNS_SANDBOX", "true").lower() in ("1", "true", "yes")
APNS_URL_OVERRIDE = os.environ.get("APNS_URL_OVERRIDE", "")   # tests only: point at a stub

# --- Storage / web ----------------------------------------------------------
DB_PATH = DATA_DIR / "events.sqlite"
AUDIO_DIR = DATA_DIR / "audio"        # per-transmission clips, for playback on the map
AUDIO_DIR.mkdir(exist_ok=True)
KEEP_AUDIO_HOURS = 24
KEEP_INCIDENT_DAYS = 7
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8000"))
