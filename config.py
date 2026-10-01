"""Central configuration. Everything can be overridden with environment variables."""
import os
from pathlib import Path

ROOT = Path(__file__).parent
DATA_DIR = ROOT / "data"
DATA_DIR.mkdir(exist_ok=True)

# --- Audio source -----------------------------------------------------------
# Broadcastify feed 14395 = "Lincoln Police and Fire, Lancaster County Sheriff"
# (official city feed, linked from lincoln.ne.gov). The raw stream URL requires
# a Broadcastify Premium account; put it in STREAM_URL. Any ffmpeg-readable
# source works here — an HTTP stream, an RTL-SDR via trunk-recorder, a local
# file for testing (see tests/).
STREAM_URL = os.environ.get("STREAM_URL", "")
STREAM_HEADERS = os.environ.get("STREAM_HEADERS", "")  # e.g. "Cookie: ...\r\n"

# --- Transcription ----------------------------------------------------------
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "small.en")   # tiny/base/small/medium/large-v3
WHISPER_DEVICE = os.environ.get("WHISPER_DEVICE", "cpu")      # "cuda" if you have a GPU
WHISPER_COMPUTE = os.environ.get("WHISPER_COMPUTE", "int8")   # int8 on CPU, float16 on GPU
VOCAB_FILE = ROOT / "lincoln_vocab.txt"

# --- Voice activity detection ---------------------------------------------
SAMPLE_RATE = 16000
MIN_SEGMENT_SEC = 0.8     # drop clicks/squelch tails shorter than this
MAX_SEGMENT_SEC = 30.0    # force-cut long runs so transcription stays responsive
SILENCE_SEC = 1.2         # gap that ends a transmission

# --- Extraction -------------------------------------------------------------
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
EXTRACT_MODEL = os.environ.get("EXTRACT_MODEL", "claude-haiku-4-5-20251001")
# Transcripts shorter than this are almost always unit acknowledgements ("10-4")
MIN_TRANSCRIPT_CHARS = 20

# --- Geocoding --------------------------------------------------------------
# Lincoln, NE bounding box: (west, south, east, north). Keeps "Vine St" in Lincoln.
LINCOLN_BBOX = (-96.85, 40.65, -96.50, 40.95)
GEOCODER = os.environ.get("GEOCODER", "nominatim")   # nominatim | mapbox
MAPBOX_TOKEN = os.environ.get("MAPBOX_TOKEN", "")
NOMINATIM_USER_AGENT = "scannermap-lincoln (personal project)"
NOMINATIM_MIN_INTERVAL = 1.1   # their usage policy: max 1 req/sec

# --- Delay handling ---------------------------------------------------------
# LPD publishes its police audio on a variable, undisclosed delay. Fire/EMS and
# Sheriff on the same feed are live. We estimate the police delay from
# dispatchers reading the clock on air (see delay.py) and back-date events.
DEFAULT_POLICE_DELAY_SEC = int(os.environ.get("DEFAULT_POLICE_DELAY_SEC", "900"))

# --- Storage / web ----------------------------------------------------------
DB_PATH = DATA_DIR / "events.sqlite"
AUDIO_DIR = DATA_DIR / "audio"        # per-transmission clips, for playback on the map
AUDIO_DIR.mkdir(exist_ok=True)
KEEP_AUDIO_HOURS = 24
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8000"))
MAP_CENTER = (40.8136, -96.7026)     # downtown Lincoln
