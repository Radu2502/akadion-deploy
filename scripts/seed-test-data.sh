#!/usr/bin/env bash
#
# seed-test-data.sh — populează Akadion cu date de test, exclusiv prin API-ul
# aplicației (fără SQL direct, fără scriere în Qdrant sau MinIO).
#
# Creează:
#   * 4 utilizatori   — 1 PROFESOR + 3 STUDENT, toți cu prefixul [TEST] în nume
#   * 3 cursuri       — deținute de profesorul de test, denumiri cu [TEST]
#   * 1 săptămână / curs
#   * 2 documente PDF / curs, urcate prin POST multipart
#
# Parola adminului NU e în cod: vine din $AKADION_ADMIN_PASSWORD sau se
# citește interactiv.
#
# Rulare:   ./scripts/seed-test-data.sh
# Curățare: ./scripts/clean-test-data.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-akadion.sh
source "${SCRIPT_DIR}/lib-akadion.sh"

WORK=$(mktemp -d -t akadion-seed-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ─── Cursurile de test: denumire|descriere ─────────────────────────────────
AK_COURSES=(
  "${AK_PREFIX} Bazele Programarii|Curs de test generat automat de seed-test-data.sh. Poate fi șters oricând."
  "${AK_PREFIX} Structuri de Date|Curs de test generat automat de seed-test-data.sh. Poate fi șters oricând."
  "${AK_PREFIX} Retele de Calculatoare|Curs de test generat automat de seed-test-data.sh. Poate fi șters oricând."
)

AK_NR_CURSURI_CREATE=0
AK_NR_DOCUMENTE_CREATE=0
AK_NR_USERI_NOI=0

# ───────────────────────────────────────────────────────────────────────────
# Aduce un utilizator în starea ACTIV cu rolul cerut.
#
# Nu există endpoint de creare de utilizatori în backend — singura cale este
# fluxul real: auto-înregistrare Keycloak -> primul login creează rândul
# app_user în starea INCOMPLET (CustomAuthenticationSuccessHandler) ->
# POST /api/auth/complete-profile -> aprobare de către admin.
# ───────────────────────────────────────────────────────────────────────────
ensure_user() { # <email> <nume> <prenume> <rol> <jar>
  local email=$1 nume=$2 prenume=$3 rol=$4 jar=$5
  local rc=0

  ak_register "$jar" "$email" "$AK_TEST_PASSWORD" || rc=$?
  case $rc in
    0) ak_info "cont Keycloak creat: ${email}"
       AK_NR_USERI_NOI=$(( AK_NR_USERI_NOI + 1 )) ;;
    2) ak_info "cont Keycloak deja existent: ${email} — mă autentific"
       ak_login "$jar" "$email" "$AK_TEST_PASSWORD" ;;
    *) ak_die "Înregistrarea lui ${email} a eșuat neașteptat (rc=${rc})." ;;
  esac

  local uid stare rol_curent
  uid=$(jq -r '.id'        <<<"$_ak_me")
  stare=$(jq -r '.stareCont' <<<"$_ak_me")
  rol_curent=$(jq -r '.rol // empty' <<<"$_ak_me")

  # INCOMPLET (cont nou) sau RESPINS (resubmisie) -> completăm profilul.
  if [[ $stare == INCOMPLET || $stare == RESPINS ]]; then
    local payload
    payload=$(jq -nc --arg n "$nume" --arg p "$prenume" \
                     --arg f "$AK_TEST_FACULTATE" --arg r "$rol" \
                     '{nume:$n, prenume:$p, facultate:$f, rolDorit:$r}')
    ak_api_json "$jar" POST /api/auth/complete-profile "$payload"
    [[ $_ak_code == 200 ]] \
      || ak_die "complete-profile a eșuat pentru ${email} (HTTP $_ak_code): $(ak_api_err)"
    stare=PENDING
    rol_curent=$rol
    ak_info "profil completat: ${nume} ${prenume} (${rol})"
  fi

  # PENDING -> aprobare de admin (PATCH /api/admin/users/{id}/approve).
  if [[ $stare == PENDING ]]; then
    ak_api "$AK_ADMIN_JAR" PATCH "/api/admin/users/${uid}/approve"
    [[ $_ak_code == 200 ]] \
      || ak_die "Aprobarea lui ${email} a eșuat (HTTP $_ak_code): $(ak_api_err)"
    stare=ACTIV
    ak_info "aprobat de admin -> ACTIV"
  elif [[ $stare == INACTIV ]]; then
    ak_api "$AK_ADMIN_JAR" POST "/api/admin/users/${uid}/activate"
    [[ $_ak_code == 200 ]] \
      || ak_die "Reactivarea lui ${email} a eșuat (HTTP $_ak_code): $(ak_api_err)"
    stare=ACTIV
    ak_info "reactivat de admin -> ACTIV"
  fi

  [[ $stare == ACTIV ]] || ak_die "${email} a rămas în starea ${stare}, nu ACTIV."
  if [[ -n $rol_curent && $rol_curent != "$rol" ]]; then
    ak_warn "${email} are rolul ${rol_curent} în DB, nu ${rol}. Rolul nu se poate schimba prin API — folosește alt email de test."
  fi

  ak_ok "utilizator ${email} — ${nume} ${prenume} [${rol}] ACTIV (id=${uid})"
}

# ───────────────────────────────────────────────────────────────────────────
main() {
  printf '\n%s\n' "Seed date de test Akadion"
  printf '%s\n\n' "backend=${AK_APP_BASE} (prin ${AK_BRIDGE_HOST}) · keycloak=http://${AK_KC_HOST}:${AK_KC_PORT}"

  command -v jq >/dev/null || ak_die "jq lipsește."

  ak_read_admin_password

  # ── 1. Sesiunea de admin ─────────────────────────────────────────────────
  ak_step "Autentificare ${AK_ADMIN_EMAIL}"
  AK_ADMIN_JAR="${WORK}/admin.jar"
  ak_login "$AK_ADMIN_JAR" "$AK_ADMIN_EMAIL" "$AK_ADMIN_PASSWORD"
  local admin_rol
  admin_rol=$(jq -r '.rol // empty' <<<"$_ak_me")
  [[ $admin_rol == ADMIN ]] \
    || ak_die "${AK_ADMIN_EMAIL} are rolul '${admin_rol:-lipsă}', nu ADMIN. Aprobarea utilizatorilor nu e posibilă."
  ak_ok "sesiune admin activă (rol=${admin_rol})"

  # ── 2. Utilizatorii de test ──────────────────────────────────────────────
  printf '\n'; ak_step "Utilizatori de test"
  local entry email nume prenume rol slug
  for entry in "${AK_USERS[@]}"; do
    IFS='|' read -r email nume prenume rol <<<"$entry"
    slug=${email%%@*}
    ensure_user "$email" "$nume" "$prenume" "$rol" "${WORK}/${slug}.jar"
  done

  # ── 3. Sesiune nouă pentru profesor ──────────────────────────────────────
  # Obligatoriu: CustomAuthoritiesMapper calculează autoritățile la login, pe
  # baza stării din DB. Sesiunea deschisă înainte de aprobare a fost creată
  # când contul era INCOMPLET/PENDING, deci nu are ROLE_PROFESOR.
  printf '\n'; ak_step "Reautentificare profesor (ca sesiunea să primească ROLE_PROFESOR)"
  local prof_jar="${WORK}/prof-activ.jar"
  ak_login "$prof_jar" "$AK_PROF_EMAIL" "$AK_TEST_PASSWORD"
  ak_ok "sesiune profesor activă: $(jq -r '.nume + " " + .prenume + " [" + .rol + "]"' <<<"$_ak_me")"

  # ── 4. Cursuri, săptămâni, documente ─────────────────────────────────────
  printf '\n'; ak_step "Cursuri, săptămâni și documente"
  local azi; azi=$(date +%F)
  local course denumire descriere payload curs_id sapt_id
  local doc_nr titlu pdf
  for course in "${AK_COURSES[@]}"; do
    IFS='|' read -r denumire descriere <<<"$course"

    payload=$(jq -nc --arg d "$denumire" --arg s "$descriere" --arg z "$azi" \
                  '{denumire:$d, descriere:$s, dataInceput:$z}')
    ak_api_json "$prof_jar" POST /api/profesor/cursuri "$payload"
    [[ $_ak_code == 201 ]] \
      || ak_die "Crearea cursului '${denumire}' a eșuat (HTTP $_ak_code): $(ak_api_err)"
    curs_id=$(jq -r '.id' <<<"$_ak_body")
    AK_NR_CURSURI_CREATE=$(( AK_NR_CURSURI_CREATE + 1 ))
    ak_ok "curs '${denumire}' (id=${curs_id})"

    # Documentele atârnă de săptămâni (documente.id_saptamana), nu de cursuri.
    # Descrierea nu poate fi null: SaptamanaService o pune într-un Map.of la
    # audit, care aruncă NPE pe valori null.
    payload=$(jq -nc --arg s "${AK_PREFIX} Saptamana 1 — materiale de test" '{descriere:$s}')
    ak_api_json "$prof_jar" POST "/api/profesor/cursuri/${curs_id}/saptamani" "$payload"
    [[ $_ak_code == 201 ]] \
      || ak_die "Crearea săptămânii pentru cursul ${curs_id} a eșuat (HTTP $_ak_code): $(ak_api_err)"
    sapt_id=$(jq -r '.id' <<<"$_ak_body")
    ak_info "săptămâna 1 (id=${sapt_id})"

    for doc_nr in 1 2; do
      titlu="${AK_PREFIX} ${denumire#"${AK_PREFIX} "} - nota de curs ${doc_nr}"
      pdf="${WORK}/curs${curs_id}-doc${doc_nr}.pdf"

      # Conținut diferit per document: DocumentService respinge upload-uri cu
      # același SHA-256 în aceeași săptămână (uq_documente_hash_saptamana).
      ak_make_pdf "$pdf" \
        "$titlu" \
        "" \
        "Document de test generat automat pentru cursul ${curs_id}," \
        "saptamana ${sapt_id}, nota ${doc_nr}." \
        "" \
        "Continut scurt, doar ca pipeline-ul de ingestie sa aiba ce indexa." \
        "Nu contine date reale si poate fi sters oricand."

      AK_TIMEOUT=$AK_UPLOAD_TIMEOUT \
        ak_api "$prof_jar" POST "/api/profesor/saptamani/${sapt_id}/documente" \
               -F "file=@${pdf};type=application/pdf" \
               -F "titlu=${titlu}"
      if [[ $_ak_code != 201 ]]; then
        ak_die "Upload-ul '${titlu}' a eșuat (HTTP $_ak_code): $(ak_api_err)"
      fi
      AK_NR_DOCUMENTE_CREATE=$(( AK_NR_DOCUMENTE_CREATE + 1 ))
      ak_info "document '${titlu}' (id=$(jq -r '.id' <<<"$_ak_body"), statusIndex=$(jq -r '.statusIndex' <<<"$_ak_body"))"
    done
  done

  # ── 5. Sumar ─────────────────────────────────────────────────────────────
  printf '\n%s\n' "Gata."
  ak_info "utilizatori de test: ${#AK_USERS[@]} (din care ${AK_NR_USERI_NOI} nou-creați în Keycloak)"
  ak_info "cursuri create: ${AK_NR_CURSURI_CREATE}"
  ak_info "documente urcate: ${AK_NR_DOCUMENTE_CREATE}"
  ak_info "parola conturilor de test: ${AK_TEST_PASSWORD}  (\$AKADION_TEST_PASSWORD)"
  printf '\n%s\n' "  statusIndex=ERONAT înseamnă doar că embedder_service nu a preluat documentul"
  printf '%s\n'   "  (RagIngestService prinde eroarea și continuă). Documentul există în DB și MinIO;"
  printf '%s\n\n' "  se poate reîncerca cu POST /api/profesor/documente/{id}/retry-ingest."
}

main "$@"
