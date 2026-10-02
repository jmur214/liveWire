# Instructions for agents working in this repo

1. Read `DESIGN.md` in full before doing anything else. Part A is the design;
   Part B is the build plan. Follow §B9 (build order) exactly, all ten steps,
   without stopping for review. The user will review when everything is done.
2. Section §B1 describes the code that already exists. Extend it; do not
   rewrite it. Keep `static/index.html` (the Leaflet web map) working.
3. Work on `main` directly, one commit per §B9 step at minimum (more is
   fine). Commit messages: imperative, one line, plus a body when the why
   isn't obvious. Push after each step so progress is visible.
4. Verify as you go. Run the replay server and exercise every endpoint
   before building the app against it. Run the Swift through `swift build`
   or `xcodebuild` if either is available; if neither is, say so in the
   final report rather than claiming it compiles.
5. When something in `DESIGN.md` is ambiguous or turns out to be wrong in
   practice, make the call that best serves Part A's intent, note it in
   `DECISIONS.md` (one line per decision: what, why), and keep going. Do
   not stop to ask.
6. Things only the user can supply are listed in §B6. Use clearly named
   placeholders (`REPLACE_ME_TEAM_ID`, etc.), list every one in `SETUP.md`
   with where it goes, and keep going.
7. Never commit `.env`, API keys, the APNs `.p8`, `data/`, or `.venv/`.
8. Finish with `REPORT.md` at the repo root: which §B5 acceptance items
   pass (verified, not assumed), which could not be verified here and why,
   every decision from `DECISIONS.md`, and the exact steps the user takes
   next (fill `SETUP.md` values, deploy, open in Xcode, install). This file
   is the first thing the user will read.
