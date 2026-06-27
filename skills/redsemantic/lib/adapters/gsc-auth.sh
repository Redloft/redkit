#!/usr/bin/env bash
# Разовый OAuth для Search Console — loopback-флоу для DESKTOP OAuth-клиента.
# Минтит refresh_token (scope webmasters.readonly) и пишет его в 1Password
# (AI-Tokens/Google Search Console/credential).
#
# 🔒 Токен НИКОГДА не попадает в stdout/транскрипт:
#   • обмен кода идёт внутри `op run` (там client_id/secret);
#   • refresh_token пишется во временный файл mode 600 (НЕ в stdout);
#   • запись в 1Password делает РОДИТЕЛЬ через `op item edit` (БЕЗ вложенного
#     `op` внутри `op run` — это и ломало запись с "invalid JSON provided");
#   • значение подставляется из файла command-substitution'ом и тут же шредится;
#   • Python не вызывает `op` → argv с токеном нигде не возникает.
#
# Предусловие: в item "Google Search Console" заполнены client_id + client_secret.
#   bash lib/adapters/gsc-auth.sh
set -euo pipefail

VAULT="AI-Tokens"; ITEM="Google Search Console"; PLACEHOLDER="ЗАПОЛНИ-В-1PASSWORD"

for f in client_id client_secret; do
  v=$(op item get "$ITEM" --vault "$VAULT" --format json 2>/dev/null | jq -r --arg l "$f" '(.fields[]?|select(.label==$l)|.value)//""')
  [ -n "$v" ] && [ "$v" != "$PLACEHOLDER" ] || { echo "✗ заполни сначала поле '$f' в item '$ITEM' (Desktop-клиент)"; exit 1; }
done

TMP=$(mktemp); chmod 600 "$TMP"
cleanup() { rm -f "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

ENVFILE=$(printf 'GSC_CLIENT_ID=op://%s/%s/client_id\nGSC_CLIENT_SECRET=op://%s/%s/client_secret\n' "$VAULT" "$ITEM" "$VAULT" "$ITEM")

# Шаг 1: consent + обмен кода ВНУТРИ op run; refresh_token → во временный файл (не stdout).
op run --env-file=<(printf '%s' "$ENVFILE") -- python3 - "$TMP" <<'PY'
import os, sys, json, socket, secrets, webbrowser
import urllib.parse, urllib.request, urllib.error, http.server

cid = os.environ["GSC_CLIENT_ID"]; csec = os.environ["GSC_CLIENT_SECRET"]
outfile = sys.argv[1]

s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
redirect = f"http://127.0.0.1:{port}"
scope = "https://www.googleapis.com/auth/webmasters.readonly"
state = secrets.token_urlsafe(16)
auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "client_id": cid, "redirect_uri": redirect, "response_type": "code",
    "scope": scope, "access_type": "offline", "prompt": "consent", "state": state})

got = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        got["code"] = p.get("code", [None])[0]; got["state"] = p.get("state", [None])[0]
        self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
        self.wfile.write("OK — можно закрыть вкладку и вернуться в терминал.".encode("utf-8"))
    def log_message(self, *a): pass

print("Открываю браузер для согласия. Если не открылось — перейди по ссылке:\n" + auth_url + "\n", file=sys.stderr)
try: webbrowser.open(auth_url)
except Exception: pass

srv = http.server.HTTPServer(("127.0.0.1", port), H); srv.timeout = 180
srv.handle_request()
if not got.get("code") or got.get("state") != state:
    sys.exit("✗ не получен code (или state не совпал). Повтори.")

data = urllib.parse.urlencode({
    "code": got["code"], "client_id": cid, "client_secret": csec,
    "redirect_uri": redirect, "grant_type": "authorization_code"}).encode()
try:
    tok = json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", data))
except urllib.error.HTTPError as e:
    # печатаем ТОЛЬКО код/первые слова ошибки, без тела с токенами
    sys.exit("✗ обмен кода не удался (HTTP %s)" % e.code)

rt = tok.get("refresh_token")
if not rt:
    sys.exit("✗ refresh_token не пришёл. Отзови доступ на https://myaccount.google.com/permissions и повтори.")

# refresh_token → во временный файл (mode 600), НЕ в stdout
fd = os.open(outfile, os.O_WRONLY | os.O_TRUNC, 0o600)
os.write(fd, rt.encode()); os.close(fd)
print("✅ refresh_token получен (во временный файл, не в терминал). Пишу в 1Password…", file=sys.stderr)
PY

# Шаг 2: запись в 1Password РОДИТЕЛЕМ (нет вложенного op-in-op-run).
# Значение из файла; в командной строке транскрипта — только $(cat ...), не токен.
if [ ! -s "$TMP" ]; then echo "✗ refresh_token не получен — запись отменена."; exit 1; fi
op item edit "$ITEM" --vault "$VAULT" "credential[concealed]=$(cat "$TMP")" >/dev/null \
  && echo "✅ refresh_token сохранён в 1Password → item '$ITEM', поле credential. Значение в терминал не выводилось." \
  || { echo "✗ op item edit не удался."; exit 1; }
