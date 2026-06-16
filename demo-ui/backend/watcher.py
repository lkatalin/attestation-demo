"""Background cluster watchers."""

from __future__ import annotations

import threading
import time

from . import oc_client
from .state import DemoState


def start_watchers(state: DemoState) -> None:
    threading.Thread(target=_poll_static, args=(state,), daemon=True).start()
    threading.Thread(target=_watch_pods, args=(state,), daemon=True).start()
    threading.Thread(target=_watch_trustee, args=(state,), daemon=True).start()


def _poll_static(state: DemoState) -> None:
    while True:
        with state._lock:
            state.refresh_static()
        with state._lock:
            snap = state.snapshot()
        state._emit({"type": "state", "state": snap})
        time.sleep(15)


def _watch_pods(state: DemoState) -> None:
    while True:
        try:
            oc_client.whoami()
        except RuntimeError:
            time.sleep(5)
            continue
        try:
            for event in oc_client.watch_pods():
                with state._lock:
                    state.on_pod_watch(event)
        except Exception as exc:
            with state._lock:
                state.error = f"pod watch: {exc}"
            time.sleep(5)


def _watch_trustee(state: DemoState) -> None:
    while True:
        try:
            oc_client.whoami()
        except RuntimeError:
            time.sleep(5)
            continue
        try:
            for line in oc_client.stream_trustee_logs():
                with state._lock:
                    state.on_trustee_line(line)
        except Exception as exc:
            with state._lock:
                state.error = f"trustee logs: {exc}"
            time.sleep(3)
