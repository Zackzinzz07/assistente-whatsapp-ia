#!/usr/bin/env bash
# Gera o QR code da instância e salva como PNG. Uso: ./scripts/qrcode.sh [instancia] [arquivo.png]
set -euo pipefail
cd "$(dirname "$0")/.."
INST=${1:-assistente}; OUT=${2:-qrcode.png}
KEY=$(grep '^AUTHENTICATION_API_KEY=' .env | cut -d= -f2)
curl -s "http://localhost:8080/instance/connect/$INST" -H "apikey: $KEY" \
 | python3 -c "import sys,json,base64; b=json.load(sys.stdin).get('base64') or sys.exit('sem QR (já conectado?)'); open('$OUT','wb').write(base64.b64decode(b.split(',',1)[1]))"
echo "QR salvo em $OUT"
