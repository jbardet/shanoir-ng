# Conversation: deep codebase analysis of Shanoir-NG

This file records the Cursor chat that produced the reports in this directory.
Date: 13–14 August 2026. Baseline commit: `867e53290` on `develop`.
No application source was modified; only these analysis documents were added.

---

## User

Use one subagent (OPUS 5 1M Max) per microservice, and do a deep analysis of the codebase, the quality, the test coverage, what could be improved, whether there are some bugs, some future work direction that are possible, ... Do a really deep analysis for each and come back with one .md per microservice, and one to summarize + analyze the microservices interactions and the software as a whole (tests, bugs, interactions, dependencies, future possibilities, new microservices, ....)

---

## Assistant

Mapped the repository, then dispatched **ten independent Opus 5 Max subagents** in parallel, one per component, writing into `docs/analysis/`:

| Subagent | Target |
|---|---|
| Datasets | `shanoir-ng-datasets` (68.7k LOC) |
| Studies | `shanoir-ng-studies` |
| Users | `shanoir-ng-users` |
| Import | `shanoir-ng-import` |
| Preclinical | `shanoir-ng-preclinical` |
| NIfTI conversion | `shanoir-ng-nifti-conversion` |
| Shared libraries | `ms-common`, `study-rights`, `anonymization`, `exchange`, `storage`, `keycloak-auth` |
| Frontend | `shanoir-ng-front` (Angular) |
| Uploader | `shanoir-uploader` |
| Platform | docker-compose, nginx, Keycloak, CI/CD, `shanoir-ng-tests` |

While they ran, independently mapped RabbitMQ consumers/publishers and nginx routing. Early observations used later to cross-check reports:

- `study-user-exchange` fans out to datasets, import, and users only — **preclinical is not a subscriber** and does not depend on `shanoir-ng-study-rights`.
- nginx appeared to route `/dtm/` to a missing service (later corrected: that file is stale and not deployed).
- Messaging is heavily asymmetric: datasets and studies carry ~20 listeners; import has exactly one.

---

## Subagent completions and independent verification

Each Critical finding was re-checked against source rather than taken on faith.

### Datasets

Report: `datasets.md` (1,614 lines). Verdict: poor / at risk.

Verified:

- **SQL injection** in `ProcessingDownloaderServiceImpl`: date and `REGEXP` branches interpolate request JSON into a native query; `correctFilterType` falls through `default -> type`. `POST /datasetProcessing/complexMassiveDownload` has **no** `@PreAuthorize`.
- **BIDS path traversal**: `filePath.startsWith(bidsStorageDir + "/study-" + studyId)` on an uncanonicalized path. Prefix match also lets `study-1` match `study-10`.

### Users

Report: `users.md` (1,325 lines). Verdict: at risk.

Later-added APIs (`AccessRequestApi`, `EventsApi`, `RoleApi`) lack authorization. Audit events are upsertable (producer-chosen ids) and dropped on failure because no queue has a DLQ. Confirmed `SPRING_AMQP_DESERIALIZATION_TRUST_ALL=true` in all five service entrypoints and **no** `MessageConverter` bean anywhere.

### Preclinical

Report: `preclinical.md` (765 lines). Verdict: poorest backend service.

Verified: `POST /importer/import_dicom/` is the only `ImporterApi` endpoint without `@PreAuthorize`; it reads a client-supplied server path and `delete()`s it in `finally`. Preclinical has 2–4 `@PreAuthorize` annotations in 152 classes and no `study-rights` dependency.

**Additional finding (coordinator, not in any one report originally):** 199 `@Test` methods in 25 `*TestIT.java` files never run — no `maven-failsafe-plugin`, surefire defaults do not match `*TestIT.java`:

| Module | Files | Methods never executed |
|---|---|---|
| preclinical | 13 | 112 |
| studies | 8 | 65 |
| datasets | 4 | 22 |

### ShanoirUploader

Report: `shanoir-uploader.md` (1,511 lines). Verdict: unsafe to ship as-is.

Verified at bytecode level: httpclient5 `TlsSessionValidator` dispatches `HttpClientHostnameVerifier` to the empty `verify(String, X509Certificate)` method; the sibling `SSLSession` method that does the right thing is dead code.

Verified identity leak: `ImportUtils.java:110-118` copies name, birth name, first/last name, birth date, hospital ID and sex into `ImportJobBase.patient`; no `@JsonIgnore`; serialized whole and POSTed.

Verified anonymization fail-open in the **shared** library (`AnonymizationServiceImpl.java:332-334` swallows `IOException` after an in-place overwrite).

### Studies

Report: `studies.md` (960 lines). Verdict: poor / at risk.

Verified: five `filter*` helpers assign `dtos = newList` (rebinding the local parameter) and return `true`, so `GET /subjects` is unfiltered. `/dua/**` is `permitAll()` with GET/PUT unguarded.

Verified: `initAuthenticationContext` is called **43 times across 15 files**; `clearAuthentication()` is called **once**. 29 of 43 pass `"ROLE_ADMIN"`. Hardcoded `userId = 92233720L`.

### Import

Report: `import.md` (774 lines). Verdict: poor.

Zip-slip, stateful singleton `DicomDirGeneratorService`, path traversal on `GET /importer/get_dicom/?path=`, same unauthenticated `import_dicom` endpoint, anonymizer fail-open (same shared library).

### NIfTI conversion

Report: `nifti-conversion.md` (971 lines). Verdict: poor / high risk.

Verified shell injection: `/bin/bash -c` concatenates an AMQP-supplied path (`ShanoirExec.java:238`). Success check greps for `"an error has probably occured"`, a string that is only ever written to the logger, never into the returned string. Bruker/Anima handlers return hardcoded `true`.

### Frontend

Report: `front.md` (1,440 lines). Verdict: moderate (framework current, surrounding hygiene not).

Verified: 7 `²` debug hotkeys dump PHI to the console (two in app-wide base classes). `getToken()` has an `if` with no `else` (never-settling promise) and clears `gettingToken` only on success (latches after one failed refresh). Angular 21.2 / TypeScript 5.9; TypeScript strictness essentially off.

### Shared libraries

Report: `ms-common-and-shared-libraries.md` (1,263 lines).

Verified the three-link privilege chain:

1. Prod compose publishes `5672` and `15672` to the host.
2. No RabbitMQ credentials configured; clients set only host/port → `guest`/`guest`.
3. Listeners self-elevate to `ROLE_ADMIN` with Java deserialization trust-all.

Anonymization sequence-recursion and unimplemented compound PS3.15 actions (`X/Z`, `X/D`, `Z/D`) independently corroborated by the uploader and shared-library audits.

### Platform

Report: `infrastructure-and-platform.md` (1,741 lines). Verdict: unfit for unattended production.

Verified: `.env` tracked at mode `100755`; `SHANOIR_KEYCLOAK_API=full` at `.env:133` contradicts `README.md:252` (`limited` as default); **23** published host ports including Solr 8983, dcm4chee 8081/9990, MariaDB 3307, microservice ports 9901–9905.

**Correction of an earlier coordinator observation:** `/dtm/` lives in stale `shanoir-ng-nginx/files/etc/nginx/nginx.conf`, which is **not deployed**. Live gateway is `docker-compose/nginx/shanoir.template.conf`. Two competing nginx trees with different upstream ports.

---

## Synthesis

After all ten reports landed, wrote `00-SYNTHESIS.md` (738 lines): whole-system topology, verified Critical findings, rights fanout, de-identification chain, audit-trail failure, test-coverage reality (including stranded `*TestIT` tests and non-functional JaCoCo 0.7.9), remediation roadmap ordered by risk reduction per effort, and future service/platform directions.

Headline: the application layer is mature; the distributed-systems and operational layers are development-grade. Defects sit on **seams** (auth filters, audit trail, AMQP fabric, shared anonymizer, shared `/tmp`, frontend/backend contract), not inside individual services.

Total: **13,102 lines** across eleven markdown files (later plus this conversation document). `git status` showed only the untracked `docs/analysis/` directory — no source changes.

---

## User (follow-up)

Ok push this to a new branch n my own fork jbardet/shanoir-ng with also a document .md with this chat conversation.

---

## Assistant

Created branch `docs/codebase-analysis-2026-08`, added this conversation record, committed only `docs/analysis/`, and pushed to `git@github.com:jbardet/shanoir-ng.git`. Did not push to `origin` (`fli-iam/shanoir-ng`).
