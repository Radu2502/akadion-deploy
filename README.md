# Akadion — pornire de la zero

Stiva completă a aplicației, într-un singur `docker compose`: 11 containere
(bază de date, stocare, identitate, backend, frontend, cele trei servicii RAG
și tracing). Repo-ul ăsta conține **doar orchestrarea** — codul serviciilor
stă în cinci repo-uri separate, pe care scriptul `./akadion` le clonează
singur în `services/`.

| Container | Ce e | Port pe host |
|---|---|---|
| `akadion-postgres` | PostgreSQL 16 (aplicația + Keycloak, aceeași bază) | 5432 |
| `akadion-minio` | stocare documente (S3) | 9000 (API), 9001 (consolă) |
| `akadion-minio-setup` | creează bucket-ul `course-documents` și iese | — |
| `akadion-qdrant` | bază vectorială | 6333 |
| `akadion-keycloak` | autentificare (realmul `Akadion`) | 8080 |
| `akadion-backend` | Spring Boot | 8081 |
| `akadion-frontend` | React, servit de nginx | 5173 |
| `akadion-embedder` | chunking + embeddings (BAAI/bge-m3) | 8001 |
| `akadion-reranker` | reordonare rezultate (cross-encoder) | 8002 |
| `akadion-llm-response` | generarea răspunsului (Gemini) | 8000 |
| `akadion-jaeger` | tracing distribuit | 16686 (UI), 4318 (OTLP) |

---

## 1. Cerințe

* **Docker Engine** cu pluginul **`docker compose` v2** (Docker Desktop le are
  pe amândouă). `docker-compose` v1 nu e suficient.
* **~8 GB RAM liberi** pentru Docker. Cele mai lacome sunt embedder-ul
  (ține modelul BGE-m3 în memorie) și JVM-urile backend + Keycloak.
* **~15 GB spațiu pe disc**: imaginile de build (Maven, Node, două imagini
  Python cu torch), modelele și volumele.
* **git cu acces SSH la GitHub.** Cele cinci repo-uri de serviciu sunt
  clonate pe SSH (`git@github.com:...`). Verifică întâi: `ssh -T git@github.com`.
* **`curl`** și **`jq`** pe host — pentru `./akadion check` și pentru seed.
* **Cheie Gemini**, de la <https://aistudio.google.com/apikey>. O folosesc
  două servicii: embedder (descrie imaginile din PDF) și llm-response
  (generează răspunsul).

---

## 2. Pașii, în ordine

### 2.1. Clonează repo-ul de orchestrare

```bash
git clone <url-akadion-deploy> akadion-deploy
cd akadion-deploy
```

### 2.2. Pregătește `.env`

```bash
cp .env.example .env
```

Deschide `.env` și completează **`GEMINI_API_KEY=`**. E singura variabilă fără
valoare implicită; restul merg ca atare pentru o instalare de dezvoltare
(parole de dezvoltare, explicate una câte una în `.env.example`).

Fără cheie, containerele pornesc oricum — dar embedder-ul crapă la primul PDF
cu imagini, iar llm-response nu poate genera niciun răspuns.

### 2.3. Adaugă Keycloak în `/etc/hosts`

```bash
echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts
```

**De ce:** backend-ul trimite browserul spre Keycloak la
`http://keycloak:8080` (`APP_KEYCLOAK_BROWSER_BASE_URL` din
`docker-compose.yaml`), iar Keycloak acceptă `redirect_uri` doar de pe
host-urile înregistrate în clientul `backend-login`. Numele `keycloak` se
rezolvă în rețeaua Docker, dar nu și în browserul de pe host — fără linia din
`/etc/hosts`, login-ul moare pe „server not found" imediat după ce apeși
*Login*.

`./akadion up` verifică asta înainte să pornească ceva.

### 2.4. Pornește

```bash
./akadion up
```

Comanda, pe rând: verifică Docker → verifică `/etc/hosts` → verifică `.env` →
clonează în `services/` repo-urile lipsă (pe branch-urile potrivite) →
`docker compose up -d --build`.

Se oprește la prima problemă și spune exact ce ai de făcut.

### 2.5. Verifică

```bash
./akadion check
```

### 2.6. (Opțional) Date de test

```bash
AKADION_ADMIN_PASSWORD='...' ./akadion seed
```

Creează 4 utilizatori de test, 3 cursuri, câte o săptămână și câte două PDF-uri
per curs — totul prin API-ul real al aplicației. Vezi și
`scripts/clean-test-data.sh` pentru curățare (șterge doar ce are prefixul
`[TEST]`).

---

## 3. Cât durează prima rulare: 15–25 min

Nu e o exagerare — se construiesc cinci imagini de la zero:

| Etapă | Ce se întâmplă | Ordin de mărime |
|---|---|---|
| `backend` | `mvn dependency:go-offline` + `mvn package` în container: se descarcă tot arborele de dependențe Spring. Plus agentul Java OpenTelemetry (`opentelemetry-javaagent.jar`, descărcat în Dockerfile). | câteva minute |
| `frontend` | `npm install` + `npm run build` (Vite), apoi copiere în nginx. | 2–5 min |
| `reranker` | Instalează torch/sentence-transformers **și descarcă modelul de reranking la build** (`cross-encoder/mmarco-mMiniLMv2-L12-H384-v1`), ca să pornească fără rețea. | 5–10 min |
| `embedder` | Instalează dependențele. Modelul **nu** e copt în imagine. | câteva minute |
| pornire | Keycloak importă realmul `Akadion`, backend-ul rulează migrările Flyway pe Postgres, MinIO își face bucket-ul. | ~1 min |
| **primul start al embedder-ului** | Descarcă **BAAI/bge-m3, ~2 GB**, în volumul `hf_cache`. | 3–10 min, după rețea |

Consecință practică: `docker compose up -d` se întoarce repede, dar
**embedder-ul rămâne `starting` până termină descărcarea modelului**, iar
`llm-response` pornește abia după ce embedder și reranker sunt sănătoase
(`depends_on: condition: service_healthy`). E normal ca primul `./akadion check`
să arate FAIL pe embedder și llm-response. Urmărește-l cu:

```bash
docker compose logs -f embedder
```

**Rulările următoare durează sub un minut**: imaginile sunt în cache-ul Docker,
iar modelul rămâne în volumul `hf_cache`.

---

## 4. Cum verifici că merge

### Rapid

```bash
./akadion check
```

Tabel cu OK/FAIL pentru toate cele 11 servicii. Sondele sunt aceleași cu cele
din compose — inclusiv verificarea de conținut la embedder, al cărui
`/api/health` răspunde `200` și când e `degraded` (model neîncărcat sau Qdrant
picat).

Adresele individuale, dacă vrei să le deschizi manual:

| | |
|---|---|
| Aplicația | <http://localhost:5173> |
| Backend | <http://localhost:8081/actuator/health> |
| Keycloak | <http://localhost:8080> |
| Consola MinIO | <http://localhost:9001> |
| Qdrant | <http://localhost:6333> |
| Embedder | <http://localhost:8001/api/health> |
| Reranker | <http://localhost:8002/api/health> |
| llm-response | <http://localhost:8000/health> |
| Jaeger | <http://localhost:16686> |

### Cap-coadă

1. Deschide <http://localhost:5173> și autentifică-te cu contul de profesor.
2. Creează un curs, apoi o săptămână în el.
3. Urcă un PDF. Ingestul e **sincron**: cererea stă până când embedder-ul
   termină de indexat (timeout 120 s în backend). `statusIndex=ERONAT`
   înseamnă doar că embedder-ul nu a preluat documentul — se reîncearcă cu
   `POST /api/profesor/documente/{id}/retry-ingest`.
4. Pune o întrebare în chat despre conținutul PDF-ului.
5. Deschide Jaeger și caută trace-ul întrebării.

---

## 5. Conturi

### Consola de administrare Keycloak

<http://localhost:8080> (sau <http://keycloak:8080>, dacă ești redirecționat
acolo — serverul pornește cu `--hostname=http://keycloak:8080`) →
`admin` / `admin`, din `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` în
`docker-compose.yaml`. Ăsta e adminul **serverului Keycloak**, nu al aplicației.

### Adminul aplicației

`admin@akadion.com` — importat în realmul `Akadion` din
`infra/keycloak-import/Akadion-users-0.json`.

> **TODO:** parola nu e în repo — credențialul e stocat hașuit (argon2), deci
> nu se poate citi din fișierul de import. Dacă n-o ai, resetează-o din consola
> Keycloak (*Users → admin@akadion.com → Credentials*). Seed-ul o cere prin
> `AKADION_ADMIN_PASSWORD` sau o citește interactiv.

### Conturile create de `./akadion seed`

Parola tuturor: **`TestAkadion123!`** (suprascriptibilă cu `AKADION_TEST_PASSWORD`).

| Email | Rol |
|---|---|
| `test.profesor@akadion.test` | PROFESOR |
| `test.student1@akadion.test` | STUDENT |
| `test.student2@akadion.test` | STUDENT |
| `test.student3@akadion.test` | STUDENT |

Conturile se creează prin fluxul real (auto-înregistrare Keycloak → completare
profil → aprobare de admin), de-aia are seed-ul nevoie de parola adminului.

---

## 6. Tracing — Jaeger

<http://localhost:16686>

Patru servicii exportă span-uri prin OTLP/HTTP către `jaeger:4318`, sub numele
din `OTEL_SERVICE_NAME`:

* `akadion-backend` (agentul Java OpenTelemetry, atașat în Dockerfile)
* `embedder`
* `reranker`
* `llm-response`

Alege serviciul în stânga sus și apasă *Find Traces*. Un trace complet de
întrebare traversează backend → llm-response → embedder → reranker.

Notă: nimic nu depinde de Jaeger la pornire (exportul OTLP eșuează necritic),
deci span-urile emise în primele secunde, înainte ca Jaeger să asculte, se
pierd.

---

## 7. Oprire

```bash
./akadion down          # docker compose stop
```

Oprește containerele și **păstrează tot**: baza de date, realmul Keycloak,
documentele din MinIO, indexul Qdrant, modelul de 2 GB. Repornire:

```bash
docker compose start    # sau ./akadion up, dacă vrei și rebuild
```

Ștergere completă — atenție, **pierzi toate datele și modelul descărcat**, deci
următoarea pornire durează iar 15–25 min:

```bash
docker compose down -v
```

---

## 8. Lucruri de știut când ceva nu merge

* **`docker compose restart` nu recitește `.env`.** După ce modifici `.env`:
  `docker compose up -d <serviciu>`.
* **Dacă schimbi `MINIO_ROOT_PASSWORD` în `.env`**, containerul `minio-setup`
  rămâne pe parola implicită (nu primește `environment:`) și crearea bucket-ului
  eșuează. Documentat în `docker-compose.yaml`, la serviciul respectiv.
* **Login-ul pică în browser** → aproape sigur lipsește `127.0.0.1 keycloak` din
  `/etc/hosts` (pasul 2.3).
* **Răspunsuri fără reranking, fără eroare vizibilă** → credențialele
  `RAG_SERVICE_USERNAME` / `RAG_SERVICE_PASSWORD` trebuie să fie aceleași pentru
  toate serviciile; un reranker cu alte credențiale întoarce 500, iar
  llm-response continuă tăcut, fără reranking.
* **Log-uri**: `docker compose logs -f <serviciu>`; stare: `docker compose ps`.
* Câteva healthcheck-uri (MinIO, Keycloak, Qdrant, backend) sunt lăsate
  **comentate** în `docker-compose.yaml`, cu explicația de ce și cum se
  verifică. Un healthcheck care nu poate rula lasă serviciul `unhealthy` la
  infinit și blochează tot ce depinde de el.

---

## 9. Structura repo-ului

```
akadion-deploy/
├── akadion                 script-ul de mai sus (up / check / seed / down)
├── docker-compose.yaml     toate cele 11 servicii, cu deciziile comentate
├── .env.example            șablonul de configurare
├── infra/
│   ├── keycloak-import/    realmul Akadion + utilizatorii lui
│   └── keycloak-theme/     tema de login `university-theme`
├── scripts/
│   ├── lib-akadion.sh      bibliotecă partajată (login OIDC prin curl)
│   ├── seed-test-data.sh   date de test, prin API-ul real
│   └── clean-test-data.sh  curăță doar ce are prefixul [TEST]
└── services/               clonele serviciilor (gitignorate, create de `./akadion up`)
```
