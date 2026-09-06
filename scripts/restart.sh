#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# start.sh already performs a strict port cleanup and verifies the newest frontend.
# Keeping restart as a single authoritative path avoids double-stop races.
exec bash "$PROJECT_DIR/scripts/start.sh"
