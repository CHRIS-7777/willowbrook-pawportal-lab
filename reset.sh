#!/usr/bin/env bash
# Rebuilds the lab from scratch: wipes the database, uploads, exports and logs.
set -euo pipefail
cd "$(dirname "$0")"
docker compose down -v --remove-orphans
docker compose up -d --build
echo "Waiting for the portal to come up..."
for i in $(seq 1 60); do
  if curl -fs -o /dev/null http://127.0.0.1:8095/; then
    echo "Ready: http://$(hostname -I | awk '{print $1}'):8095/"
    exit 0
  fi
  sleep 2
done
echo "Portal did not respond in time - check: docker compose logs web" >&2
exit 1
