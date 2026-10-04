#!/bin/bash
# Usage: ./run-backend.sh A   (on Mac 3, port 3001)
#        ./run-backend.sh B   (on Mac 4, port 3002)
set -e
ID="$1"
if [ "$ID" = "A" ]; then
    PORT=3001
elif [ "$ID" = "B" ]; then
    PORT=3002
else
    echo "Usage: $0 A|B"
    exit 1
fi

cd "$(dirname "$0")/../backend"
python3 -m venv .venv 2>/dev/null || true
source .venv/bin/activate
pip install -q -r requirements.txt
BACKEND_ID="$ID" PORT="$PORT" python3 app.py
