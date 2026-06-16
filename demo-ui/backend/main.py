"""FastAPI server + WebSocket for live demo topology UI."""

from __future__ import annotations

import os
from pathlib import Path

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .state import DemoState
from .watcher import start_watchers

ROOT = Path(__file__).resolve().parent.parent
STATIC = ROOT / "static"
DEFAULT_PROMPT = os.environ.get(
    "DEMO_PROMPT", "encrypted model weights stay ciphertext until"
)

app = FastAPI(title="Confidential Inferencing Demo UI")
state = DemoState()
state.default_prompt = DEFAULT_PROMPT


class PromptBody(BaseModel):
    prompt: str | None = None
    max_new_tokens: int = 35


@app.on_event("startup")
def startup() -> None:
    with state._lock:
        state.refresh_static()
    start_watchers(state)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True}


@app.get("/api/state")
def get_state() -> dict:
    with state._lock:
        return state.snapshot()


@app.get("/api/kbs/policies")
def kbs_policies() -> dict:
    with state._lock:
        state.refresh_static()
        return {
            "resourcePolicy": state.kbs.get("resourcePolicy", ""),
            "imagePolicy": state.kbs.get("imagePolicy", ""),
            "secrets": state.kbs.get("secrets", []),
        }


@app.get("/api/initdata")
def initdata() -> dict:
    with state._lock:
        return {"toml": state.initdata}


@app.post("/api/clear-session")
def clear_session() -> dict:
    snap = state.clear_session()
    return {"ok": True, "state": snap}


@app.get("/api/flows/{flow_id}")
def flow_detail(flow_id: str) -> dict:
    with state._lock:
        for f in state.parser.flows:
            if f.id == flow_id:
                return f.to_dict()
    return {"error": "flow not found"}


@app.post("/api/prompt")
async def prompt_confidential(body: PromptBody) -> dict:
    prompt = body.prompt or state.default_prompt
    with state._lock:
        host = state.kbs.get("endpoint", "").replace("https://", "")
    if not host:
        return {"ok": False, "error": "confidential route not found"}
    url = f"https://{host}/v1/generate"
    payload = {"prompt": prompt, "max_new_tokens": body.max_new_tokens}
    try:
        async with httpx.AsyncClient(verify=False, timeout=30.0) as client:
            resp = await client.post(url, json=payload)
            data = resp.json() if resp.headers.get("content-type", "").startswith("application/json") else {"text": resp.text}
        result = {"ok": resp.is_success, "status": resp.status_code, "data": data}
    except Exception as exc:
        result = {"ok": False, "error": str(exc)}
    with state._lock:
        state.apply_prompt_result(prompt, result)
    return {"prompt": prompt, **result}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    loop = __import__("asyncio").get_running_loop()

    def listener(event: dict) -> None:
        __import__("asyncio").run_coroutine_threadsafe(ws.send_json(event), loop)

    state.subscribe(listener)
    try:
        with state._lock:
            initial = state.snapshot()
        await ws.send_json({"type": "state", "state": initial})
        while True:
            msg = await ws.receive_text()
            if msg == "refresh":
                with state._lock:
                    state.refresh_static()
                    refreshed = state.snapshot()
                await ws.send_json({"type": "state", "state": refreshed})
    except WebSocketDisconnect:
        pass
    finally:
        try:
            state._listeners.remove(listener)
        except ValueError:
            pass


if STATIC.is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC / "assets"), name="assets")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(STATIC / "index.html")

    @app.get("/{path:path}")
    def spa(path: str) -> FileResponse:
        candidate = STATIC / path
        if candidate.is_file():
            return FileResponse(candidate)
        return FileResponse(STATIC / "index.html")
