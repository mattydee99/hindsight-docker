#!/bin/zsh
# Hindsight backfill progress — polls every 30s
TOTAL_DOCS=152

while true; do
  DATA=$(curl -s "http://localhost:8889/v1/default/banks/research/stats" 2>/dev/null)
  if [[ -z "$DATA" ]]; then
    echo "$(date '+%H:%M:%S')  [offline]"
  else
    python3 - <<EOF
import json, sys
d = json.loads('''$DATA''')
ops      = d["operations_by_status"]
done     = ops.get("completed", 0)
pending  = ops.get("pending", 0)
running  = ops.get("processing", 0)
failed   = d["failed_operations"]
docs     = d["total_documents"]
total    = done + pending
pct      = done / total * 100 if total else 0
bar_len  = 30
filled   = int(bar_len * pct / 100)
bar      = "█" * filled + "░" * (bar_len - filled)

from datetime import datetime
ts = datetime.now().strftime("%H:%M:%S")
print(f"{ts}  [{bar}] {pct:4.0f}%  ops {done}/{total}  docs {docs}/$TOTAL_DOCS  active {running}  failed {failed}")
if pending == 0 and running == 0:
    print("         ✓ Queue empty — backfill complete")
    sys.exit(0)
EOF
    [[ $? -eq 0 ]] && break
  fi
  sleep 30
done
