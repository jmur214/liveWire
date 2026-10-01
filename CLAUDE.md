# Instructions for agents working in this repo

1. Read `DESIGN.md` in full before doing anything else. Part A is the design;
   Part B is the build plan. Follow §B9 (build order) exactly.
2. Section §B1 describes the code that already exists. Extend it; do not
   rewrite it. Keep `static/index.html` (the Leaflet web map) working.
3. **Stop after §B9 step 3** (replay mode, schema, grouping, core API, SSE).
   Open a pull request titled "Server: replay mode, incidents, API" with a
   short note showing sample `/api/incidents` output from the replay. Wait
   for review before starting the iOS work in step 4.
4. After that, one PR per §B9 step. Each PR description lists which §B5
   acceptance items it satisfies.
5. Never commit `.env`, API keys, the APNs `.p8`, `data/`, or `.venv/`.
6. Things only the user can supply are listed in §B6. Use placeholders and
   note them in the PR; do not block on them.
7. Branch from `main` as `step-N-<short-name>`. Commit messages: imperative,
   one line, plus a body when the why isn't obvious.
