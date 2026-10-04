"""
Minimal REST backend for the Computer Networks course project.
Run the SAME file for Backend A (BACKEND_ID=A, PORT=3001) and
Backend B (BACKEND_ID=B, PORT=3002).

Usage:
    BACKEND_ID=A PORT=3001 python3 app.py
"""
import os
import socket
from flask import Flask, jsonify, make_response, request

app = Flask(__name__)
BACKEND_ID = os.environ.get("BACKEND_ID", "A")
PORT = int(os.environ.get("PORT", 3001))
ETAG = '"cn-cache-v1"'


@app.route("/")
def home():
    resp = make_response(
        jsonify(
            backend=BACKEND_ID,
            message=f"Backend {BACKEND_ID} is running",
            hostname=socket.gethostname(),
        )
    )
    resp.headers["X-Backend"] = BACKEND_ID
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/status")
def status():
    resp = make_response(
        jsonify(
            backend=BACKEND_ID,
            status="ok",
            hostname=socket.gethostname(),
        )
    )
    resp.headers["X-Backend"] = BACKEND_ID
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/cache")
def cache():
    if request.headers.get("If-None-Match") == ETAG:
        resp = make_response("", 304)
        resp.headers["X-Backend"] = BACKEND_ID
        resp.headers["ETag"] = ETAG
        resp.headers["Cache-Control"] = "public, max-age=60"
        return resp

    resp = make_response(
        jsonify(
            backend=BACKEND_ID,
            message="CN cache example",
            cached_data="Fresh response from server",
        )
    )
    resp.headers["X-Backend"] = BACKEND_ID
    resp.headers["ETag"] = ETAG
    resp.headers["Cache-Control"] = "public, max-age=60"
    return resp


if __name__ == "__main__":
    # host=0.0.0.0 is required so OTHER Macs / clients on the LAN can reach this service.
    print(f"Backend {BACKEND_ID} starting on 0.0.0.0:{PORT}")
    app.run(host="0.0.0.0", port=PORT)
