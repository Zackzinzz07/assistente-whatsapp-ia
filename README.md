# Assistente de WhatsApp com IA — Evolution API + n8n

Servidor de WhatsApp auto-hospedado com [Evolution API v2](https://github.com/evolution-foundation/evolution-api) em Docker, exposto pela internet com ngrok e integrado ao **n8n cloud**, onde um agente de IA responde as mensagens privadas (DMs) usando o histórico real da conversa.

```
 WhatsApp ──► Evolution API ──webhook (MESSAGES_UPSERT)──► n8n cloud
   ▲          (Docker, no PC)                                 │
   │              ▲                                           ▼
   │              └──── ngrok (domínio estático) ◄──── busca histórico + IA (ChatGPT/Gemini)
   └──────────────────────── POST /message/sendText ◄──────── resposta
```

## Stack

| Serviço | Imagem | Função |
|---|---|---|
| `evolution-api` | `evoapicloud/evolution-api:v2.3.7` | API REST do WhatsApp (Baileys) + painel `/manager` |
| `postgres` | `postgres:15-alpine` | Instâncias, mensagens, contatos e webhooks |
| `redis` | `redis:7-alpine` | Cache |
| `ngrok` | `ngrok/ngrok:3-alpine` | Túnel HTTPS com domínio estático gratuito |

Todos os serviços usam `restart: unless-stopped` e volumes nomeados, então a sessão do WhatsApp sobrevive a reinícios. A API só escuta em `127.0.0.1`: o acesso externo é só pelo ngrok, e o Postgres e o Redis não expõem porta nenhuma.

## Estrutura

```
.
├── docker-compose.yml        # os 4 serviços
├── .env.example              # modelo de configuração (copie para .env)
├── scripts/qrcode.sh         # gera o QR code de conexão como PNG
├── scripts/webhook.sh        # aponta o webhook para o n8n, com token de autenticação
└── n8n/
    ├── assistente-ia-whatsapp.json   # agente de IA (importar no n8n)
    └── saudacao-whatsapp.json        # alternativa simples: saudação 1x por dia
```

## Instalação

**Pré-requisitos:** Docker com Compose v2, uma conta gratuita no [ngrok](https://dashboard.ngrok.com/signup) e uma conta no n8n.

1. **Configuração**
   ```bash
   cp .env.example .env
   chmod 600 .env
   ```
   Preencha no `.env`:
   - `AUTHENTICATION_API_KEY`: gere com `openssl rand -hex 32`.
   - `POSTGRES_PASSWORD`: gere com `openssl rand -hex 24`, e use a mesma senha dentro da `DATABASE_CONNECTION_URI`.
   - `NGROK_AUTHTOKEN`: está em *Getting Started → Your Authtoken* (não confunda com o ID do domínio, que começa com `rd_`).
   - `NGROK_DOMAIN` e `SERVER_URL`: o seu domínio em *Domains*. Desligue o tradutor do navegador para copiar, porque ele traduz o nome do domínio.
   - `WEBHOOK_TOKEN`: gere com `openssl rand -hex 24`. É ele que impede que alguém forje mensagens no seu webhook.

2. **Subir**
   ```bash
   docker compose up -d
   docker compose logs -f evolution-api   # espere "HTTP - ON: 8080"
   ```

3. **Criar a instância e conectar o WhatsApp**
   ```bash
   KEY=$(grep '^AUTHENTICATION_API_KEY=' .env | cut -d= -f2)
   curl -s -X POST http://localhost:8080/instance/create -H "apikey: $KEY" \
     -H 'Content-Type: application/json' \
     -d '{"instanceName":"assistente","integration":"WHATSAPP-BAILEYS","qrcode":true}'
   ./scripts/qrcode.sh          # gera qrcode.png (vale ~40 s)
   ```
   Escaneie em *WhatsApp → Dispositivos conectados*. Também dá para usar `http://localhost:8080/manager`, onde o login é a apikey.

4. **n8n**: nenhum segredo fica escrito nos nós, tudo vai em credenciais criptografadas.
   - Em *Credentials → Add credential → Header Auth*, crie duas credenciais:

     | Nome da credencial | Name | Value |
     |---|---|---|
     | `Evolution API` | `apikey` | `AUTHENTICATION_API_KEY` do `.env` |
     | `Evolution webhook` | `x-webhook-token` | `WEBHOOK_TOKEN` do `.env` |

   - Em *Workflows → Import from file*, importe `n8n/assistente-ia-whatsapp.json`. Os nós já apontam para essas duas credenciais: confira se estão selecionadas no nó **Mensagem recebida** e nos 3 nós HTTP;
   - nos 3 nós HTTP, troque `SEU-DOMINIO.ngrok-free.dev` pelo seu domínio;
   - conecte uma credencial ao nó **ChatGPT** (ou ligue o **Gemini** no lugar);
   - publique e copie a *Production URL* do nó **Mensagem recebida**.

5. **Webhook da instância**: liga o evento `MESSAGES_UPSERT` e envia o `WEBHOOK_TOKEN` no cabeçalho `x-webhook-token`.
   ```bash
   ./scripts/webhook.sh PRODUCTION_URL_DO_N8N
   ```

## Como o agente de IA funciona

1. **Autentica e filtra**: o nó Webhook recusa requisições sem o cabeçalho `x-webhook-token` correto (Header Auth), e o filtro aceita só `jid` no formato de telefone (`^\d{8,15}@s.whatsapp.net$`). A instância é fixa: nada do corpo vai direto para URLs ou consultas, e os corpos das requisições são montados com `JSON.stringify`. Também só responde DMs com texto e ignora grupos (`@g.us`), status, canais e mensagens enviadas pelo próprio número (`fromMe`), o que evita loop.
2. **Agrupa**: espera 10 s e só a execução da *última* mensagem da sequência responde. Assim, várias mensagens seguidas geram uma resposta só.
3. **Busca o contexto**: lê as últimas mensagens do chat em `POST /chat/findMessages`, com duas buscas, porque a Evolution guarda as mensagens recebidas pelo `@lid` (com `remoteJidAlt`) e as enviadas pela API pelo número.
4. **Diferencia quem falou**: as mensagens enviadas pela API (IA) não têm `addressingMode` e têm `source: web`. As do dono vêm sincronizadas do celular.
5. **Pausa**: se o dono escreveu no chat nos últimos 30 minutos (`PAUSA_MINUTOS` no nó *Montar contexto*), a IA não responde.
6. **Responde**: o agente (gpt-5-mini) recebe o histórico com as três vozes (contato, dono e assistente) e responde em 1 ou 2 frases. Ele não fala pelo dono, não inventa compromissos e não promete "vou avisar".

Para responder uma mensagem que caiu na pausa, reenvie o evento ao webhook com `"forcar": true` no corpo. Ele também precisa do cabeçalho com o token.

## Comandos do dia a dia

```bash
docker compose ps                       # status
docker compose logs -f evolution-api    # logs ao vivo (Ctrl+C sai)
docker compose stop                     # parar (mantém dados)
docker compose start                    # voltar (sem QR novo)
docker compose restart evolution-api    # reiniciar só a API
```

**Atualizar:** troque a tag da imagem em `docker-compose.yml` (veja as [releases](https://github.com/evolution-foundation/evolution-api/releases)) e rode:
```bash
docker compose pull evolution-api && docker compose up -d evolution-api
```

> ⚠️ `docker compose down -v` apaga os volumes: você perde a sessão do WhatsApp e o banco.

## Segurança

- O `.env`, os QR codes (`*.png`) e os logs **nunca** vão para o Git. Os logs com `LOG_LEVEL` detalhado mostram o texto das mensagens e chaves de sessão.
- O QR code dá acesso à conta do WhatsApp: não compartilhe.
- A apikey vale para a API inteira. Se vazar, gere outra no `.env` e reinicie com `docker compose up -d`.
- A URL do webhook do n8n é pública: sem o `WEBHOOK_TOKEN`, qualquer pessoa poderia forjar mensagens e fazer o seu número enviar texto para terceiros. Se ele vazar, gere outro e rode `scripts/webhook.sh` de novo.
- A Evolution usa uma conexão **não oficial** do WhatsApp (Baileys). Envio em massa ou para quem não te chamou pode levar ao banimento do número.

## Limitações conhecidas

- Áudio, foto e figurinha sozinhos não recebem resposta.
- Resposta em ~15–20 s, por causa da janela de agrupamento.
- O Docker Desktop no Linux só sobe depois do login. Para funcionar como servidor de verdade, use o Docker Engine nativo.
