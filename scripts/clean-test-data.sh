#!/usr/bin/env bash
#
# clean-test-data.sh — șterge datele de test create de seed-test-data.sh,
# exclusiv prin API-ul aplicației. Atinge DOAR ce are prefixul [TEST].
#
# Ce face, în ordine:
#   1. documentele cu titlu [TEST]      -> DELETE /api/profesor/documente/{id}
#                                          (soft: activ=false + ștergere din MinIO și RAG)
#   2. săptămânile cu descriere [TEST]  -> DELETE /api/profesor/saptamani/{id}
#                                          (ștergere reală; doar ultima săptămână,
#                                           deci se merge de la coadă spre început)
#   3. cursurile cu denumire [TEST]     -> PATCH /api/profesor/cursuri/{id}/dezactiveaza
#
# CE NU FACE:
#   * Nu șterge cursuri. Backend-ul nu expune DELETE pe cursuri — doar
#     dezactivare. Rândul rămâne în tabela `cursuri` cu activ=false.
#   * Nu atinge utilizatorii [TEST]. Rămân ACTIV, ca seed-ul să poată rula din
#     nou fără reînregistrare. (Oricum nu există DELETE pe utilizatori, doar
#     POST /api/admin/users/{id}/deactivate.)
#
# Plase de siguranță — un curs [TEST] e curățat doar dacă:
#   * numele profesorului proprietar începe tot cu [TEST];
#   * în săptămâna vizată nu a rămas niciun document fără prefixul [TEST]
#     (ștergerea unei săptămâni șterge din DB toate documentele ei, inclusiv
#     pe cele care nu sunt de test — vezi SaptamanaService).
#
# Rulare:
#   ./scripts/clean-test-data.sh              # curăță
#   ./scripts/clean-test-data.sh --dry-run    # arată ce ar șterge, fără să șteargă
#   ./scripts/clean-test-data.sh --fara-audit # sare peste scanarea finală

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-akadion.sh
source "${SCRIPT_DIR}/lib-akadion.sh"

WORK=$(mktemp -d -t akadion-clean-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

DRY_RUN=0
AUDIT=1
for arg in "$@"; do
  case $arg in
    --dry-run|-n)  DRY_RUN=1 ;;
    --fara-audit)  AUDIT=0 ;;
    -h|--help)     awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             ak_die "Argument necunoscut: ${arg}" ;;
  esac
done

NR_DOC=0; NR_SAPT=0; NR_CURS=0; NR_SKIP=0

has_prefix() { [[ $1 == "${AK_PREFIX}"* ]]; }

# Cache de sesiuni de profesor, indexat pe email.
declare -A PROF_JAR=()

prof_session() { # <email> -> setează REPLY cu calea către cookie jar, sau 1
  local email=$1 jar
  if [[ -n ${PROF_JAR[$email]:-} ]]; then
    REPLY=${PROF_JAR[$email]}
    [[ $REPLY == FAILED ]] && return 1
    return 0
  fi
  jar="${WORK}/prof-${email//[^a-zA-Z0-9]/_}.jar"
  if ak_try_login "$jar" "$email" "$AK_TEST_PASSWORD"; then
    PROF_JAR[$email]=$jar
    REPLY=$jar
    return 0
  fi
  PROF_JAR[$email]=FAILED
  ak_warn "Nu m-am putut autentifica drept ${email} — sar peste cursurile lui. ${_ak_login_err}"
  ak_warn "  (parola conturilor de test se dă prin \$AKADION_TEST_PASSWORD)"
  return 1
}

# ───────────────────────────────────────────────────────────────────────────
curata_saptamana() { # <jar-profesor> <id-saptamana> <descriere> -> 0 dacă poate fi ștearsă
  local jar=$1 sid=$2 descr=$3
  local docs ramase did titlu

  ak_api "$jar" GET "/api/profesor/saptamani/${sid}/documente"
  [[ $_ak_code == 200 ]] || { ak_warn "Nu pot citi documentele săptămânii ${sid} (HTTP $_ak_code)"; return 1; }
  docs=$_ak_body

  # 1. documentele [TEST]
  while IFS=$'\t' read -r did titlu; do
    [[ -z $did ]] && continue
    if (( DRY_RUN )); then
      ak_info "[dry-run] aș șterge documentul ${did} — ${titlu}"
    else
      AK_TIMEOUT=$AK_UPLOAD_TIMEOUT ak_api "$jar" DELETE "/api/profesor/documente/${did}"
      if [[ $_ak_code != 204 ]]; then
        ak_warn "Ștergerea documentului ${did} a eșuat (HTTP $_ak_code): $(ak_api_err || true)"
        return 1
      fi
      ak_info "document șters: ${did} — ${titlu}"
    fi
    NR_DOC=$(( NR_DOC + 1 ))
  done < <(jq -r --arg p "$AK_PREFIX" '.[] | select(.titlu | startswith($p)) | "\(.id)\t\(.titlu)"' <<<"$docs")

  # 2. mai există documente care NU sunt de test? Atunci nu atingem săptămâna:
  #    SaptamanaService.stergeSaptamanaSiAuditeaza ar șterge și documentele alea.
  ramase=$(jq -r --arg p "$AK_PREFIX" '[.[] | select(.titlu | startswith($p) | not)] | length' <<<"$docs")
  if (( ramase > 0 )); then
    ak_warn "Săptămâna ${sid} ('${descr}') are ${ramase} document(e) fără prefix [TEST] — nu o șterg."
    return 1
  fi

  # 3. săptămâna însăși, doar dacă e marcată [TEST]
  if ! has_prefix "$descr"; then
    ak_warn "Săptămâna ${sid} nu are prefixul [TEST] ('${descr}') — nu o șterg."
    return 1
  fi
  return 0
}

curata_curs() { # <id> <denumire>
  local cid=$1 denumire=$2
  local prof_mail prof_nume jar saptamani sid nr descr

  ak_api "$AK_ADMIN_JAR" GET "/api/admin/cursuri/${cid}/profesor"
  if [[ $_ak_code != 200 ]]; then
    ak_warn "Nu pot afla profesorul cursului ${cid} (HTTP $_ak_code) — sar peste."
    NR_SKIP=$(( NR_SKIP + 1 )); return 0
  fi
  prof_mail=$(jq -r '.mail' <<<"$_ak_body")
  prof_nume=$(jq -r '.nume // ""' <<<"$_ak_body")

  # Plasă de siguranță: nu ne atingem de cursurile colegilor, chiar dacă
  # cineva a numit un curs cu [TEST] din greșeală.
  if ! has_prefix "$prof_nume"; then
    ak_warn "Cursul ${cid} '${denumire}' aparține lui ${prof_mail} (nume '${prof_nume}', fără prefix [TEST]) — nu îl ating."
    NR_SKIP=$(( NR_SKIP + 1 )); return 0
  fi

  if ! prof_session "$prof_mail"; then
    NR_SKIP=$(( NR_SKIP + 1 )); return 0
  fi
  jar=$REPLY

  printf '\n'; ak_step "Curs ${cid} — ${denumire}  (profesor: ${prof_mail})"

  ak_api "$jar" GET "/api/profesor/cursuri/${cid}/saptamani"
  if [[ $_ak_code != 200 ]]; then
    ak_warn "Nu pot citi săptămânile cursului ${cid} (HTTP $_ak_code) — sar peste."
    NR_SKIP=$(( NR_SKIP + 1 )); return 0
  fi
  saptamani=$_ak_body

  # De la ultima spre prima: SaptamanaService.stergeUltimaSaptamana refuză
  # orice altceva decât săptămâna cu nrSaptamana maxim.
  while IFS=$'\t' read -r sid nr descr; do
    [[ -z $sid ]] && continue
    if ! curata_saptamana "$jar" "$sid" "$descr"; then
      ak_warn "Mă opresc din ștergerea săptămânilor cursului ${cid} (doar ultima poate fi ștearsă)."
      break
    fi
    if (( DRY_RUN )); then
      ak_info "[dry-run] aș șterge săptămâna ${nr} (id=${sid}) — ${descr}"
    else
      ak_api "$jar" DELETE "/api/profesor/saptamani/${sid}"
      if [[ $_ak_code != 204 ]]; then
        ak_warn "Ștergerea săptămânii ${sid} a eșuat (HTTP $_ak_code): $(ak_api_err || true)"
        break
      fi
      ak_info "săptămână ștearsă: ${nr} (id=${sid})"
    fi
    NR_SAPT=$(( NR_SAPT + 1 ))
  done < <(jq -r 'sort_by(.nrSaptamana) | reverse | .[] | "\(.id)\t\(.nrSaptamana)\t\(.descriere // "")"' <<<"$saptamani")

  # Cursul: doar dezactivare — nu există DELETE în CursProfesorController.
  if (( DRY_RUN )); then
    ak_info "[dry-run] aș dezactiva cursul ${cid}"
  else
    ak_api "$jar" PATCH "/api/profesor/cursuri/${cid}/dezactiveaza"
    if [[ $_ak_code != 200 ]]; then
      ak_warn "Dezactivarea cursului ${cid} a eșuat (HTTP $_ak_code): $(ak_api_err || true)"
      return 0
    fi
    ak_info "curs dezactivat (activ=false; rândul rămâne în DB)"
  fi
  NR_CURS=$(( NR_CURS + 1 ))
}

# Scanare read-only: raportează resturi [TEST] agățate de cursuri care NU sunt
# de test — acolo nu avem sesiunea profesorului proprietar ca să le ștergem.
audit_resturi() {
  local cid denumire sid descr n total=0
  while IFS=$'\t' read -r cid denumire; do
    [[ -z $cid ]] && continue
    ak_api "$AK_ADMIN_JAR" GET "/api/admin/cursuri/${cid}/saptamani"
    [[ $_ak_code == 200 ]] || continue
    while IFS=$'\t' read -r sid descr; do
      [[ -z $sid ]] && continue
      if has_prefix "$descr"; then
        ak_warn "rest: săptămâna ${sid} '${descr}' e sub cursul non-test ${cid} '${denumire}'"
        total=$(( total + 1 ))
      fi
      ak_api "$AK_ADMIN_JAR" GET "/api/admin/saptamani/${sid}/documente"
      [[ $_ak_code == 200 ]] || continue
      n=$(jq -r --arg p "$AK_PREFIX" '[.[] | select(.titlu | startswith($p))] | length' <<<"$_ak_body")
      if (( n > 0 )); then
        ak_warn "rest: ${n} document(e) [TEST] în săptămâna ${sid} a cursului non-test ${cid} '${denumire}'"
        total=$(( total + 1 ))
      fi
    done < <(jq -r '.[] | "\(.id)\t\(.descriere // "")"' <<<"$_ak_body")
  done < <(jq -r --arg p "$AK_PREFIX" '.[] | select(.denumire | startswith($p) | not) | "\(.id)\t\(.denumire)"' <<<"$AK_ALL_COURSES")
  if (( total == 0 )); then
    ak_ok "audit: nu există resturi [TEST] sub cursuri care nu sunt de test"
  else
    ak_warn "audit: ${total} rest(uri) [TEST] necesită sesiunea profesorului proprietar — șterge-le manual."
  fi
}

# ───────────────────────────────────────────────────────────────────────────
main() {
  printf '\n%s\n' "Curățare date de test Akadion"
  if (( DRY_RUN )); then printf '%s\n' "MOD DRY-RUN — nu se modifică nimic."; fi
  printf '%s\n\n' "backend=${AK_APP_BASE} (prin ${AK_BRIDGE_HOST}) · prefix='${AK_PREFIX}'"

  command -v jq >/dev/null || ak_die "jq lipsește."

  ak_read_admin_password

  ak_step "Autentificare ${AK_ADMIN_EMAIL}"
  AK_ADMIN_JAR="${WORK}/admin.jar"
  ak_login "$AK_ADMIN_JAR" "$AK_ADMIN_EMAIL" "$AK_ADMIN_PASSWORD"
  [[ $(jq -r '.rol // empty' <<<"$_ak_me") == ADMIN ]] \
    || ak_die "${AK_ADMIN_EMAIL} nu are rolul ADMIN."
  ak_ok "sesiune admin activă"

  ak_api "$AK_ADMIN_JAR" GET /api/admin/cursuri
  [[ $_ak_code == 200 ]] || ak_die "GET /api/admin/cursuri a răspuns HTTP $_ak_code: $(ak_api_err || true)"
  AK_ALL_COURSES=$_ak_body

  local nr_test cid denumire
  nr_test=$(jq -r --arg p "$AK_PREFIX" '[.[] | select(.denumire | startswith($p))] | length' <<<"$AK_ALL_COURSES")
  ak_info "cursuri în total: $(jq 'length' <<<"$AK_ALL_COURSES") · cu prefixul [TEST]: ${nr_test}"

  if (( nr_test > 0 )); then
    while IFS=$'\t' read -r cid denumire; do
      [[ -z $cid ]] && continue
      curata_curs "$cid" "$denumire"
    done < <(jq -r --arg p "$AK_PREFIX" '.[] | select(.denumire | startswith($p)) | "\(.id)\t\(.denumire)"' <<<"$AK_ALL_COURSES")
  fi

  if (( AUDIT )); then
    printf '\n'; ak_step "Audit resturi [TEST]"
    audit_resturi
  fi

  if (( DRY_RUN )); then
    printf '\n%s\n' "Gata (dry-run — nimic nu s-a modificat)."
  else
    printf '\n%s\n' "Gata."
  fi
  ak_info "documente șterse:    ${NR_DOC}"
  ak_info "săptămâni șterse:    ${NR_SAPT}"
  ak_info "cursuri dezactivate: ${NR_CURS}"
  if (( NR_SKIP > 0 )); then ak_info "cursuri sărite:      ${NR_SKIP}"; fi
  printf '\n%s\n'   "  Utilizatorii [TEST] NU au fost atinși — rămân ACTIV, ca seed-ul să poată"
  printf '%s\n'     "  rula din nou fără reînregistrare în Keycloak. Pentru a-i dezactiva manual:"
  printf '%s\n\n'   "    POST /api/admin/users/{id}/deactivate  (nu există DELETE pe utilizatori)"
}

main
