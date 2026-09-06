#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
bash "$PROJECT_DIR/scripts/stop.sh" || true
bash "$PROJECT_DIR/scripts/start.sh"
