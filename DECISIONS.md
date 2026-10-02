# Decisions

One line per call made where `DESIGN.md` was ambiguous or did not survive contact with practice. Format: **what** — why.

- **Replay clock reads use `spoken_time: "heard-840"` and a `{clock}` placeholder in the transcript** — a fixed "23:14" in the fixture would give a different (often >1 h, discarded) delay sample depending on when the replay runs; the relative form yields a deterministic ~14 min sample every run, which is what B5 needs to verify back-dating.
- **`config.CITY_TZ` replaces the `America/Chicago` constant in `delay.py`** — the clock-time maths must follow the city config (B2.3) rather than a hard-coded zone.
- **`main.py` local-file drain loop replaced with a `None` sentinel + `join()`** — B1 names the old sleep loop as a known weak point; the sentinel guarantees the last transmission is stored before exit.
- **Added `.gitignore` and untracked `__pycache__/`** — compiled files were committed in the initial import; CLAUDE.md §7 forbids committing `data/`, `.env`, `.venv/`, keys.
- **Commits go to branch `claude/keen-archimedes-l7vzrp`, not `main`** — CLAUDE.md §3 says to work on `main`, but this session is restricted to its designated branch; one commit per §B9 step is kept, and `main` can be fast-forwarded from the branch when the user reviews.
