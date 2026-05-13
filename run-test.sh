#!/usr/bin/env bash
# Roda k6 com dashboard ao vivo e arquiva o resultado em test/history/<timestamp>/.
# Uso: ./run-test.sh "descricao opcional pra log do terminal"
#
# Por run, o history guarda:
#   - results.json   : scoring completo (committed)
#   - report.html    : snapshot do dashboard k6 (gitignored, local)
#   - k6.log         : log textual do run (gitignored, local)
#
# Descricao + estado do codigo vem do git commit que adicionou esse history
# ao repo. Pra contexto: `git log -- test/history/<ts>/`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NOTE="${1:-}"
TS="$(date +%Y-%m-%dT%H-%M-%S)"
HIST_DIR="test/history/$TS"
mkdir -p "$HIST_DIR"

echo "=> ${NOTE:-(sem descricao)}"
echo "=> dashboard: http://localhost:5665"
echo "=> arquivando em: $HIST_DIR"

K6_WEB_DASHBOARD=true \
K6_WEB_DASHBOARD_OPEN=true \
K6_WEB_DASHBOARD_PORT=5665 \
K6_WEB_DASHBOARD_EXPORT="$HIST_DIR/report.html" \
K6_NO_USAGE_REPORT=true \
k6 run test/test.js 2>&1 | tee "$HIST_DIR/k6.log"

# results.json e escrito pelo test.js em test/results.json; move pro history
mv test/results.json "$HIST_DIR/results.json"

FINAL_SCORE=$(/usr/bin/python3 - "$HIST_DIR/results.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["scoring"]["final_score"])
PY
)

echo
echo "=> arquivado: $HIST_DIR"
echo "=> final_score: $FINAL_SCORE"
