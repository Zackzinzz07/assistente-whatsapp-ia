#!/usr/bin/env bash
# Aponta o webhook da instância para o n8n, enviando o WEBHOOK_TOKEN no cabeçalho x-webhook-token.
# Uso: ./scripts/webhook.sh <production_url_do_n8n> [instancia]
set -euo pipefail
cd "$(dirname "$0")/.."
URL=${1:?informe a Production URL do webhook do n8n}; INST=${2:-assistente}
KEY=$(grep '^AUTHENTICATION_API_KEY=' .env | cut -d= -f2)
TOKEN=$(grep '^WEBHOOK_TOKEN=' .env | cut -d= -f2)
[ -n "$TOKEN" ] || { echo "WEBHOOK_TOKEN vazio no .env" >&2; exit 1; }
curl -s -X POST "http://localhost:8080/webhook/set/$INST" -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d "{\"webhook\":{\"enabled\":true,\"url\":\"$URL\",\"headers\":{\"x-webhook-token\":\"$TOKEN\"},\"byEvents\":false,\"base64\":false,\"events\":[\"MESSAGES_UPSERT\"]}}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('webhook:', d.get('url'), '| ativo:', d.get('enabled'), '| eventos:', d.get('events'), '| com token:', bool(d.get('headers')))"
