#!/usr/bin/env bash
# Bibliotecă partajată de seed-test-data.sh și clean-test-data.sh.
# Nu se rulează direct — se încarcă cu `source`.
#
# ─── De ce arată autentificarea așa ────────────────────────────────────────
# Backend-ul NU e resource server: în SecurityConfig.java nu există nicio
# configurare de tip JWT/bearer. Tot API-ul merge pe sesiune de browser:
#   oauth2Login (Authorization Code) -> cookie JSESSIONID
#   csrf.spa()                        -> cookie XSRF-TOKEN, retrimis în
#                                        header-ul X-XSRF-TOKEN
# Deci nu există „un token de admin". Simulăm exact ce face browserul.
#
# ─── De ce --connect-to și nu pur și simplu host.docker.internal ───────────
# Numele de host contează, nu doar portul:
#   * Keycloak acceptă redirect_uri doar din lista clientului `backend-login`
#     (infra/keycloak-import/Akadion-realm.json):
#         http://localhost:5173/*
#         http://localhost:8081/login/oauth2/code/keycloak
#         http://localhost:8081/login/oauth2/code/keycloak-register
#     Spring construiește redirect_uri din header-ul Host al cererii, deci
#     trebuie să vorbim cu backend-ul ca „localhost:8081". Dacă l-am apela ca
#     „host.docker.internal:8081", Keycloak ar răspunde „Invalid parameter:
#     redirect_uri".
#   * Backend-ul trimite browserul spre Keycloak pe „keycloak:8080"
#     (APP_KEYCLOAK_BROWSER_BASE_URL din infra/docker-compose.yaml).
# curl --connect-to păstrează Host-ul din URL, dar deschide conexiunea TCP
# spre altă adresă — exact ce ne trebuie din devcontainer, unde nu avem Docker.

# ─── Topologie (toate suprascriptibile din environment) ─────────────────────
AK_BRIDGE_HOST="${AK_BRIDGE_HOST:-$(getent hosts host.docker.internal >/dev/null 2>&1 && echo host.docker.internal || echo 127.0.0.1)}"
AK_APP_HOST="${AK_APP_HOST:-localhost}"
AK_APP_PORT="${AK_APP_PORT:-8081}"
AK_KC_HOST="${AK_KC_HOST:-keycloak}"
AK_KC_PORT="${AK_KC_PORT:-8080}"

AK_APP_BASE="http://${AK_APP_HOST}:${AK_APP_PORT}"

AK_CONNECT=(
  --connect-to "${AK_APP_HOST}:${AK_APP_PORT}:${AK_BRIDGE_HOST}:${AK_APP_PORT}"
  --connect-to "${AK_KC_HOST}:${AK_KC_PORT}:${AK_BRIDGE_HOST}:${AK_KC_PORT}"
)

# Ingestul RAG e sincron în DocumentService.adaugaDocument, cu read timeout de
# 120s în RagIngestService.init(). Upload-ul poate sta blocat până se termină.
AK_TIMEOUT="${AK_TIMEOUT:-60}"
AK_UPLOAD_TIMEOUT="${AK_UPLOAD_TIMEOUT:-180}"

# ─── Convenția de date de test ─────────────────────────────────────────────
AK_PREFIX='[TEST]'
AK_TEST_PASSWORD="${AKADION_TEST_PASSWORD:-TestAkadion123!}"
AK_TEST_DOMAIN="${AKADION_TEST_DOMAIN:-akadion.test}"
AK_TEST_FACULTATE="${AK_PREFIX} Facultatea de Informatica"

AK_PROF_EMAIL="test.profesor@${AK_TEST_DOMAIN}"

# email|nume|prenume|rol  — numele poartă prefixul [TEST], cerut de temă.
AK_USERS=(
  "${AK_PROF_EMAIL}|${AK_PREFIX} Ionescu|Mihai|PROFESOR"
  "test.student1@${AK_TEST_DOMAIN}|${AK_PREFIX} Popescu|Ana|STUDENT"
  "test.student2@${AK_TEST_DOMAIN}|${AK_PREFIX} Georgescu|Bogdan|STUDENT"
  "test.student3@${AK_TEST_DOMAIN}|${AK_PREFIX} Dumitrescu|Carmen|STUDENT"
)

# ─── Ieșire ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  AK_C_OK=$'\033[32m'; AK_C_WARN=$'\033[33m'; AK_C_ERR=$'\033[31m'
  AK_C_DIM=$'\033[2m';  AK_C_OFF=$'\033[0m'
else
  AK_C_OK=''; AK_C_WARN=''; AK_C_ERR=''; AK_C_DIM=''; AK_C_OFF=''
fi

ak_info() { printf '%s\n' "  $*"; }
ak_step() { printf '%s\n' "${AK_C_DIM}··${AK_C_OFF} $*"; }
ak_ok()   { printf '%s\n' "${AK_C_OK}OK${AK_C_OFF} $*"; }
ak_warn() { printf '%s\n' "${AK_C_WARN}!!${AK_C_OFF} $*" >&2; }
ak_die()  { printf '%s\n' "${AK_C_ERR}EROARE${AK_C_OFF} $*" >&2; exit 1; }

# Director pentru corpurile de răspuns salvate la diagnostic.
AK_DEBUG_DIR="${AK_DEBUG_DIR:-$(mktemp -d -t akadion-scripts-XXXXXX)}"
ak_dump() { # $1 = eticheta ; salvează ultimul body și întoarce calea
  local f="${AK_DEBUG_DIR}/$1.$$.html"
  printf '%s' "${_ak_body}" > "$f"
  printf '%s' "$f"
}

# ─── Motor HTTP ────────────────────────────────────────────────────────────
# ak_req <cookie-jar> <argumente curl...> <url>
# Nu urmărește redirecturi: fluxul OIDC are nevoie de control pas cu pas.
# Rezultatele ajung în variabilele globale de mai jos.
_ak_body=''; _ak_code=''; _ak_loc=''; _ak_rc=0

ak_req() {
  local jar=$1; shift
  local tmp meta
  tmp=$(mktemp)
  _ak_rc=0
  meta=$(curl -sS "${AK_CONNECT[@]}" \
              --cookie "$jar" --cookie-jar "$jar" \
              --max-time "$AK_TIMEOUT" \
              --output "$tmp" \
              --write-out '%{http_code}\t%{redirect_url}' \
              "$@" 2>&1) || _ak_rc=$?
  if (( _ak_rc != 0 )); then
    _ak_code='000'; _ak_loc=''; _ak_body="$meta"
    rm -f "$tmp"
    return 0
  fi
  _ak_code=${meta%%$'\t'*}
  _ak_loc=${meta#*$'\t'}
  _ak_body=$(cat "$tmp")
  rm -f "$tmp"
  return 0
}

# Citește tokenul CSRF brut din cookie jar (format Netscape: câmp 6 = nume,
# câmp 7 = valoare). Frontend-ul face exact la fel — vezi src/api/client.ts.
ak_csrf() {
  awk -F'\t' '$6=="XSRF-TOKEN"{v=$7} END{print v}' "$1" 2>/dev/null
}

# ak_api <jar> <metoda> <cale> [argumente curl...]
ak_api() {
  local jar=$1 method=$2 path=$3; shift 3
  ak_req "$jar" -X "$method" \
         -H "X-XSRF-TOKEN: $(ak_csrf "$jar")" \
         -H 'Accept: application/json' \
         "$@" "${AK_APP_BASE}${path}"
}

ak_api_json() { # ak_api_json <jar> <metoda> <cale> <corp-json>
  ak_api "$1" "$2" "$3" -H 'Content-Type: application/json;charset=UTF-8' --data-binary "$4"
}

# Mesajul de eroare din răspunsurile GlobalExceptionHandler ({"status":..,"eroare":".."})
ak_api_err() {
  printf '%s' "${_ak_body}" | jq -r '.eroare // .message // empty' 2>/dev/null
}

# ─── Parsare HTML Keycloak ─────────────────────────────────────────────────
ak_unescape() {
  sed -e 's/&amp;/\&/g' -e 's/&quot;/"/g' -e 's/&#39;/'"'"'/g' \
      -e 's/&#x27;/'"'"'/g' -e 's/&lt;/</g' -e 's/&gt;/>/g'
}

# Extrage action-ul unui <form>. Încearcă întâi după id (kc-form-login /
# kc-register-form, identice în tema `keycloak` implicită și în tema custom
# infra/keycloak-theme/university-theme), apoi cade pe primul form din pagină.
ak_form_action() { # <html> <id-form>
  local html=$1 id=$2 tag action
  # `|| true` peste tot: cu `set -e` + `pipefail`, un grep fără potriviri ar
  # opri scriptul înainte să apucăm să încercăm varianta de rezervă.
  tag=$(printf '%s' "$html" | tr '\n' ' ' | grep -o "<form[^>]*id=\"${id}\"[^>]*>" | head -1 || true)
  [[ -z $tag ]] && tag=$(printf '%s' "$html" | tr '\n' ' ' | grep -o '<form[^>]*action="[^"]*"[^>]*>' | head -1 || true)
  [[ -z $tag ]] && return 1
  action=$(printf '%s' "$tag" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//' || true)
  [[ -z $action ]] && return 1
  printf '%s' "$action" | ak_unescape
}

ak_form_has_field() { # <html> <nume-camp>
  printf '%s' "$1" | grep -q "name=\"$2\""
}

# Mesajul de eroare afișat de Keycloak în pagină (best effort).
ak_kc_error() {
  printf '%s' "${_ak_body}" \
    | tr '\n' ' ' \
    | grep -o '<span[^>]*id="input-error[^"]*"[^>]*>[^<]*</span>\|<div[^>]*kc-feedback-text[^>]*>[^<]*</div>' \
    | sed -e 's/<[^>]*>//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' | head -1 | ak_unescape
}

# ─── Flux OIDC ─────────────────────────────────────────────────────────────
# Urmează redirecturile până ajungem înapoi pe backend (callback-ul cu ?code=)
# sau până primim o pagină HTML de la Keycloak.
_ak_follow_until_form() {
  local jar=$1 url=$2 hop=0
  while (( hop++ < 8 )); do
    ak_req "$jar" "$url"
    [[ $_ak_code != 3* ]] && return 0
    url=$_ak_loc
    [[ -z $url ]] && return 0
    # Am ajuns înapoi la backend => Keycloak ne-a autentificat deja prin SSO.
    if [[ $url == "${AK_APP_BASE}/login/oauth2/code/"* ]]; then
      _ak_loc=$url; _ak_code='302'; return 0
    fi
  done
  return 1
}

# Duce la bun sfârșit schimbul code -> sesiune și verifică /api/auth/me.
# Umple _ak_me cu JSON-ul utilizatorului.
_ak_me=''
_ak_finish_callback() {
  local jar=$1 url=$2
  ak_req "$jar" "$url"
  if [[ $_ak_code != 3* ]]; then
    ak_die "Schimbul de cod OAuth2 a eșuat (HTTP $_ak_code). Răspuns salvat în $(ak_dump callback)"
  fi
  ak_req "$jar" "${AK_APP_BASE}/api/auth/me"
  if [[ $_ak_code != 200 ]]; then
    ak_die "Sesiune creată dar /api/auth/me a răspuns HTTP $_ak_code: $(ak_api_err). Detalii în $(ak_dump me)"
  fi
  _ak_me=$_ak_body
}

# ak_login <jar> <email> <parola>
# La final: jar-ul conține JSESSIONID + XSRF-TOKEN, iar _ak_me are profilul.
ak_login() {
  local jar=$1 email=$2 password=$3
  : > "$jar"

  ak_req "$jar" "${AK_APP_BASE}/oauth2/authorization/keycloak"
  if [[ $_ak_code != 3* ]]; then
    ak_die "Backend-ul nu a pornit fluxul de login (HTTP $_ak_code). Rulează aplicația pe ${AK_BRIDGE_HOST}:${AK_APP_PORT}?"
  fi

  _ak_follow_until_form "$jar" "$_ak_loc" \
    || ak_die "Prea multe redirecturi în fluxul de autorizare Keycloak."

  # SSO deja activ (nu ar trebui cu jar gol, dar tratăm cazul).
  if [[ $_ak_code == 3* && $_ak_loc == "${AK_APP_BASE}/login/oauth2/code/"* ]]; then
    _ak_finish_callback "$jar" "$_ak_loc"
    return 0
  fi

  if [[ $_ak_code != 200 ]]; then
    ak_die "Pagina de login Keycloak a răspuns HTTP $_ak_code. Detalii în $(ak_dump login-page)"
  fi

  local action
  action=$(ak_form_action "$_ak_body" 'kc-form-login') \
    || ak_die "Nu am găsit formularul de login în pagina Keycloak. Detalii în $(ak_dump login-page)"

  ak_req "$jar" --data-urlencode "username=${email}" \
                --data-urlencode "password=${password}" \
                --data-urlencode 'credentialId=' \
                "$action"

  if [[ $_ak_code != 3* ]]; then
    local msg; msg=$(ak_kc_error || true)
    ak_die "Autentificare respinsă pentru ${email}${msg:+ — Keycloak: $msg}. Detalii în $(ak_dump login-post)"
  fi

  _ak_finish_callback "$jar" "$_ak_loc"
}

# ak_register <jar> <email> <parola>
# Auto-înregistrare prin formularul Keycloak (realmul are registrationAllowed).
# Întoarce 0 dacă a creat contul, 2 dacă emailul există deja.
ak_register() {
  local jar=$1 email=$2 password=$3
  : > "$jar"

  # `keycloak-register` adaugă prompt=create — vezi CustomAuthorizationRequestResolver.
  ak_req "$jar" "${AK_APP_BASE}/oauth2/authorization/keycloak-register"
  if [[ $_ak_code != 3* ]]; then
    ak_die "Backend-ul nu a pornit fluxul de înregistrare (HTTP $_ak_code)."
  fi

  _ak_follow_until_form "$jar" "$_ak_loc" \
    || ak_die "Prea multe redirecturi în fluxul de înregistrare Keycloak."

  if [[ $_ak_code != 200 ]]; then
    ak_die "Pagina de înregistrare Keycloak a răspuns HTTP $_ak_code. Detalii în $(ak_dump register-page)"
  fi

  local action page
  page=$_ak_body
  action=$(ak_form_action "$page" 'kc-register-form') \
    || ak_die "Nu am găsit formularul de înregistrare. Detalii în $(ak_dump register-page)"

  # Realmul are registrationEmailAsUsername=true, iar user profile-ul declară
  # doar username + email (fără firstName/lastName). Le trimitem doar dacă
  # formularul chiar le conține.
  local -a fields=(
    --data-urlencode "email=${email}"
    --data-urlencode "password=${password}"
    --data-urlencode "password-confirm=${password}"
  )
  if ak_form_has_field "$page" 'username';  then fields+=(--data-urlencode "username=${email}"); fi
  if ak_form_has_field "$page" 'firstName'; then fields+=(--data-urlencode "firstName=Test");    fi
  if ak_form_has_field "$page" 'lastName';  then fields+=(--data-urlencode "lastName=Akadion");  fi

  ak_req "$jar" "${fields[@]}" "$action"

  if [[ $_ak_code != 3* ]]; then
    # Cel mai probabil: emailul e deja folosit. Semnalăm apelantului.
    return 2
  fi

  _ak_finish_callback "$jar" "$_ak_loc"
  return 0
}

# ─── Generator de PDF ──────────────────────────────────────────────────────
# DocumentService.validateFile acceptă DOAR pdf/docx/pptx/zip, cu verificare
# Tika pe conținutul real — un .txt redenumit e respins. Scriem deci un PDF
# minim, valid structural (xref cu offseturi corecte), cu text ASCII.
# Fără diacritice: Helvetica/WinAnsiEncoding nu are ă/ș/ț.
ak_pdf_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/(/\\(/g' -e 's/)/\\)/g'
}

# ak_make_pdf <fisier-iesire> <linie...>
ak_make_pdf() {
  local out=$1; shift
  local content='BT /F1 12 Tf 56 780 Td 16 TL' line len xref
  for line in "$@"; do
    content+=" ($(ak_pdf_escape "$line")) Tj T*"
  done
  content+=' ET'
  len=$(printf '%s' "$content" | wc -c)

  : > "$out"
  local -a offs=()
  _ak_obj() { offs+=("$(wc -c < "$out")"); printf '%s' "$1" >> "$out"; }

  printf '%%PDF-1.4\n' > "$out"
  _ak_obj $'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
  _ak_obj $'2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'
  _ak_obj $'3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n'
  _ak_obj $'4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n'
  # printf -v, nu $(...): substituția de comandă ar tăia \n-ul final, iar
  # `endobj` s-ar lipi de `xref`.
  local obj5
  printf -v obj5 '5 0 obj\n<< /Length %d >>\nstream\n%s\nendstream\nendobj\n' "$len" "$content"
  _ak_obj "$obj5"

  xref=$(wc -c < "$out")
  # Fiecare intrare xref are exact 20 de octeți, inclusiv spațiul dinaintea \n.
  printf 'xref\n0 6\n0000000000 65535 f \n' >> "$out"
  local o; for o in "${offs[@]}"; do printf '%010d 00000 n \n' "$o" >> "$out"; done
  printf 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$xref" >> "$out"

  unset -f _ak_obj
}

# ─── Parola de admin ───────────────────────────────────────────────────────
# Nu se hardcodează niciodată: fie din environment, fie citită interactiv.
ak_read_admin_password() {
  if [[ -n ${AKADION_ADMIN_PASSWORD:-} ]]; then
    AK_ADMIN_PASSWORD=$AKADION_ADMIN_PASSWORD
    return 0
  fi
  [[ -t 0 ]] || ak_die "Parola adminului lipsește. Setează AKADION_ADMIN_PASSWORD sau rulează scriptul într-un terminal interactiv."
  printf 'Parola pentru %s: ' "$AK_ADMIN_EMAIL" >&2
  read -rs AK_ADMIN_PASSWORD
  printf '\n' >&2
  [[ -n $AK_ADMIN_PASSWORD ]] || ak_die "Parolă goală."
}

AK_ADMIN_EMAIL="${AKADION_ADMIN_EMAIL:-admin@akadion.com}"

# ak_try_login <jar> <email> <parola>
# Variantă neletală a lui ak_login, pentru bucle care nu trebuie oprite de un
# singur cont care nu merge. Motivul eșecului rămâne în _ak_login_err.
_ak_login_err=''
ak_try_login() {
  local jar=$1 email=$2 password=$3 tmp out rc=0
  tmp=$(mktemp)
  out=$( ak_login "$jar" "$email" "$password" 2>"$tmp" >/dev/null && printf '%s' "$_ak_me" ) || rc=$?
  _ak_login_err=$(tr -d '\r' < "$tmp" | tr '\n' ' ')
  rm -f "$tmp"
  if (( rc == 0 )); then
    _ak_me=$out
    return 0
  fi
  return 1
}
