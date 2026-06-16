#!/usr/bin/env python3
"""Run the confidential inferencing demo UI server."""

import os
import sys

# Allow `python -m backend.main` from demo-ui/
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import uvicorn

if __name__ == "__main__":
    host = os.environ.get("DEMO_UI_HOST", "127.0.0.1")
    port = int(os.environ.get("DEMO_UI_PORT", "8765"))
    uvicorn.run(
        "backend.main:app",
        host=host,
        port=port,
        reload=os.environ.get("DEMO_UI_RELOAD") == "1",
    )
