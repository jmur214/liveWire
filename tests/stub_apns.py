"""Fake APNs endpoint for local testing of push.py.

    python tests/stub_apns.py                   # 127.0.0.1:8098
    APNS_URL_OVERRIDE=http://127.0.0.1:8098 python main.py --replay tests/fixtures/lincoln_day.json --speed 20

Records every POST /3/device/{token} and returns 200 (or 410 for tokens that
start with "dead"). GET /sent lists what was received.
"""
from __future__ import annotations

import sys

import uvicorn
from fastapi import FastAPI, Request, Response

app = FastAPI()
sent: list[dict] = []


@app.post("/3/device/{token}")
async def deliver(token: str, request: Request):
    body = await request.json()
    sent.append({"token": token, "headers": {k: v for k, v in request.headers.items() if k.startswith("apns-") or k == "authorization"},
                 "payload": body})
    print(f"push -> {token[:12]}… {body['aps']['alert']}", flush=True)
    if token.startswith("dead"):
        return Response(status_code=410, content='{"reason":"Unregistered"}', media_type="application/json")
    return Response(status_code=200)


@app.get("/sent")
def get_sent():
    return {"sent": sent}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(sys.argv[1]) if len(sys.argv) > 1 else 8098, log_level="warning")
