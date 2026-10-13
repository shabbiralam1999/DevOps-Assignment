#!/usr/bin/env bash
# Generates load for HPA + rate limit demos. Usage: scripts/load-test.sh [url] [seconds]
URL="${1:-http://node-react.local/api/items}"
SECS="${2:-120}"
end=$((SECONDS+SECS))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" "$URL" & done
  wait
done | sort | uniq -c
