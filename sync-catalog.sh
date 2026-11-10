#!/usr/bin/env bash
# Lanza el workflow "Sync releases.md" de GitHub desde la terminal.
# Uso:  ./sync-catalog.sh          -> lanza y termina
#       ./sync-catalog.sh --wait   -> lanza y espera al resultado
# Requiere: curl (y un token fine-grained con "Actions: Read and write").

set -u

OWNER="lexusytg"
REPO="POOG-Portal"
BRANCH="main"
WORKFLOW="sync-releases.yml"

TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/poog/token"
API="https://api.github.com/repos/$OWNER/$REPO"

WAIT=0
[ "${1:-}" = "--wait" ] || [ "${1:-}" = "-w" ] && WAIT=1

# --- Token: busca el que ya tengas configurado; pregunta solo como último recurso ---
TOKEN=""; SRC=""
find_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then TOKEN="$GITHUB_TOKEN"; SRC="variable GITHUB_TOKEN"; return; fi
  if [ -n "${GH_TOKEN:-}" ]; then TOKEN="$GH_TOKEN"; SRC="variable GH_TOKEN"; return; fi
  if command -v gh >/dev/null 2>&1; then
    t="$(gh auth token 2>/dev/null)"
    [ -n "$t" ] && { TOKEN="$t"; SRC="gh auth"; return; }
  fi
  # Credenciales de git (las que usas para git push a github.com)
  if command -v git >/dev/null 2>&1; then
    t="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')"
    [ -n "$t" ] && { TOKEN="$t"; SRC="credenciales de git"; return; }
  fi
  if [ -f "$HOME/.git-credentials" ]; then
    t="$(grep -m1 'github.com' "$HOME/.git-credentials" | sed -n 's#^https://[^:]*:\([^@]*\)@.*#\1#p')"
    [ -n "$t" ] && { TOKEN="$t"; SRC="~/.git-credentials"; return; }
  fi
  if [ -f "$TOKEN_FILE" ]; then TOKEN="$(cat "$TOKEN_FILE")"; SRC="$TOKEN_FILE"; return; fi
}
find_token

if [ -z "$TOKEN" ]; then
  echo "No encontré ningún token configurado."
  read -rsp "Pega tu token de GitHub: " TOKEN </dev/tty; echo
  [ -z "$TOKEN" ] && { echo "Sin token, no puedo continuar."; exit 1; }
  read -rp "¿Guardarlo en $TOKEN_FILE? [s/N] " ans </dev/tty
  if [ "$ans" = "s" ] || [ "$ans" = "S" ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    ( umask 077; printf '%s' "$TOKEN" > "$TOKEN_FILE" )
    echo "Guardado (solo legible por tu usuario)."
  fi
else
  echo "Usando token de: $SRC"
fi

gh_api() {  # gh_api <curl args...>
  curl -s -H "Authorization: Bearer $TOKEN" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

latest_run() {
  gh_api "$API/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=1"
}

before_id=""
if [ "$WAIT" -eq 1 ]; then
  before_id="$(latest_run | grep -m1 -o '"id": *[0-9]*' | grep -o '[0-9]*')"
fi

# --- Lanzar ---
code="$(gh_api -o /dev/null -w '%{http_code}' -X POST \
        -d "{\"ref\":\"$BRANCH\"}" "$API/actions/workflows/$WORKFLOW/dispatches")"

case "$code" in
  204) echo "✔ Workflow lanzado en $OWNER/$REPO ($BRANCH)." ;;
  401|403) echo "✘ Token rechazado ($code). Necesita Actions: Read and write sobre $REPO."
           echo "  El token usado venía de: ${SRC:-entrada manual}. Prueba con otro: GITHUB_TOKEN=xxx ./sync-catalog.sh"; exit 1 ;;
  404) echo "✘ No se encontró $WORKFLOW en $OWNER/$REPO (¿está subido a la rama $BRANCH?)."; exit 1 ;;
  422) echo "✘ El workflow no admite ejecución manual (falta workflow_dispatch) o la rama no existe."; exit 1 ;;
  *)   echo "✘ Error inesperado (HTTP $code)."; exit 1 ;;
esac

[ "$WAIT" -eq 0 ] && { echo "Mira el progreso en: https://github.com/$OWNER/$REPO/actions"; exit 0; }

# --- Esperar al resultado (máx. ~3 min) ---
echo -n "Esperando"
for _ in $(seq 1 45); do
  sleep 4; echo -n "."
  run="$(latest_run)"
  id="$(echo "$run" | grep -m1 -o '"id": *[0-9]*' | grep -o '[0-9]*')"
  [ "$id" = "$before_id" ] && continue
  status="$(echo "$run" | grep -m1 -o '"status": *"[^"]*"' | cut -d'"' -f4)"
  if [ "$status" = "completed" ]; then
    concl="$(echo "$run" | grep -m1 -o '"conclusion": *"[^"]*"' | cut -d'"' -f4)"
    echo
    if [ "$concl" = "success" ]; then echo "✔ Catálogo actualizado."; exit 0
    else echo "✘ El workflow terminó con: $concl. Revisa https://github.com/$OWNER/$REPO/actions"; exit 1; fi
  fi
done
echo
echo "Sigue en curso. Revisa https://github.com/$OWNER/$REPO/actions"
