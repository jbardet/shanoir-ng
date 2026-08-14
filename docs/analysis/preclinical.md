# `shanoir-ng-preclinical` — Engineering Audit

**Scope:** `shanoir-ng-preclinical` (20,570 LOC, 152 main / 58 test classes) at commit `867e53290`.
**Method:** static read of the source tree. Every claim is cited as `path:LINE`. Two claims were verified empirically with a standalone JDK 25 probe (noted inline). No build was run; nothing was modified.

---

## 1. Executive summary

`shanoir-ng-preclinical` manages the animal-specific extension of the Shanoir domain: animal subjects, a generic reference-value catalogue (species, strain, biotype, provider, stabulation…), pathologies and pathology models, therapies, anaesthetics, contrast agents, examination "extra data" file attachments, and the Bruker→DICOM upload entry point.

**Health verdict: poor — the weakest backend service in the platform.** It is not merely under-tested or dated; it has a *structural* authorization gap (it cannot enforce study-user rights at all), a large body of validation code that is provably inert, and it is the reason an unauthenticated-by-annotation arbitrary-file-read/delete endpoint exists in `shanoir-ng-import`. The high test-class count is misleading: 22 % of test classes never execute, and the ones that do are ~85 % copy-paste templates asserting mock round-trips.

### Top findings, ranked

| # | Severity | Finding | Anchor |
|---|---|---|---|
| 1 | **Critical** | `POST /importer/import_dicom/` in `shanoir-ng-import` takes a client-supplied absolute server path, reads it, and `delete()`s it in a `finally` block. It is the **only** endpoint in `ImporterApi` with no `@PreAuthorize`. It exists solely to serve the preclinical Bruker flow. | `shanoir-ng-import/.../ImporterApi.java:132`, `ImporterApiController.java:374-387` |
| 2 | **Critical** | The service does not participate in the study-user rights model **at all**: 2 `@PreAuthorize` in 152 classes (vs 154 in studies, 193 in datasets), no `shanoir-ng-study-rights` dependency, no `studySecurityService`. Any authenticated user can read/modify/delete any animal subject, pathology, therapy or global reference value in any study. | `SecurityConfiguration.java:74-79`; `shanoir-ng-preclinical/pom.xml` |
| 3 | **Critical** | Zip Slip in the Bruker upload: zip entry names are concatenated into a path with no traversal check, so an uploaded archive can write arbitrary files onto the shared `tmp` docker volume. | `BrukerApiController.java:190-208` |
| 4 | **High** | 22 of 25 validator classes are provably no-ops. Zero `@EditableOnlyBy` annotations exist, so all 12 `*EditableByManager` beans always return an empty error map; only 3 entities carry `@Unique`, so 10 of 13 unique validators do nothing. Every `getCreationRightsErrors`/`getUpdateRightsErrors` call in every controller is theatre. | `rg @EditableOnlyBy src/main` → 0 hits; `Therapy.java:42`, `Pathology.java:39`, `PathologyModel.java:44` are the only `@Unique` |
| 5 | **High** | The Bruker RPC uses the *default* 5 s `RabbitTemplate` reply timeout (preclinical never configures `spring.rabbitmq.template.reply-timeout`, unlike studies' 60 s) and then unboxes the reply with `(boolean)`. Any real conversion exceeds 5 s → `null` reply → `NullPointerException` → HTTP 422 "Error while saving uploaded file". | `BrukerApiController.java:139`; `shanoir-ng-studies/src/main/resources/application.yml:77` |
| 6 | **High** | Systematic IDOR: nested resources are fetched/deleted by their own id after only checking that the *parent* exists, never that the child belongs to the parent. `DELETE /subject/1/therapy/999` deletes therapy 999 even if it belongs to another subject. | `SubjectTherapyApiController.java:110-124,148-163`; `SubjectPathologyApiController.java:106-112,148-154`; `ExaminationAnestheticApiController.java:107-115` (ignores `{id}` entirely) |
| 7 | **High** | `.gitignore`'s `nullbruker/` entry documents a real, currently-regressed bug. The 2020 fix set a system property in a static JUnit-4 `@BeforeClass`; the JUnit 5 migration turned it into a non-static `@BeforeEach` that runs *after* the Spring context is built, so it no longer has any effect. The Bruker test now writes uncleaned directories into the real `/tmp/bruker/convert/` on every CI run. | `BrukerApiControllerTest.java:67-71` (method still named `beforeClass`); commits `24f3a11f9`, `3accad469` |
| 8 | **Medium** | Test suite is far weaker than 58 classes suggests: 13 `*TestIT.java` classes / 112 `@Test` methods are **never run** (surefire's default includes don't match `*TestIT.java`), and they assert `HttpStatus.FOUND` for unauthenticated access — the pre-OAuth2 behaviour. Of the 37 that do run, sibling service tests are 83 % identical line-for-line. | see §8 |

---

## 2. Purpose & domain responsibilities

The service owns the **animal-specific** slice of the domain. It does *not* own preclinical subjects or examinations outright — those live in the clinical services and carry a boolean discriminator:

- `shanoir-ng-studies` owns `Subject`, with `Subject.preclinical` (`shanoir-ng-studies/.../subject/model/Subject.java:102`).
- `shanoir-ng-datasets` owns `Examination`, with `Examination.preclinical` (`shanoir-ng-datasets/.../examination/model/Examination.java:142`).
- `shanoir-ng-preclinical` owns `AnimalSubject`, which **shares the primary key** of the clinical `Subject` (`AnimalSubject.java:46-47`: `@Id private Long id;` with no `@GeneratedValue`).

Responsibilities:

1. **Animal subject extension** — specie/strain/biotype/provider/stabulation, each a `Reference`.
2. **Reference catalogue** — a single `reference(category, reftype, refvalue)` table backing every dropdown in the preclinical UI.
3. **Pathologies** — `Pathology`, `PathologyModel` (with a PDF spec attachment), `SubjectPathology` (subject × pathology × location × date range).
4. **Therapies** — `Therapy`, `SubjectTherapy` (dose, unit, frequency, molecule, date range).
5. **Anaesthetics** — `Anesthetic`, `AnestheticIngredient`, `ExaminationAnesthetic` (links to a `datasets` examination id).
6. **Contrast agents** — `ContrastAgent`, linked to a `protocolId` owned elsewhere.
7. **Extra data** — `ExaminationExtraData` / `PhysiologicalData` / `BloodGasData`, single-table-per-hierarchy with file attachments.
8. **Bruker upload** — accepts a Bruker `.zip`, unpacks it, delegates conversion to `nifti-conversion` over AMQP, re-zips the DICOM output.

The service also carries an OWL ontology (`docs/ontology/ontoneurolog-preclinic.owl`) and a 2,591-line OpenAPI contract (`docs/shanoir-ng-preclinical.yaml`) that is maintained separately from the springdoc-generated one.

---

## 3. Architecture & code structure

### 3.1 Package tree

| Package | Classes | LOC | Notes |
|---|---:|---:|---|
| `preclinical/pathologies` (+ `pathology_models`, `subject_pathologies`) | 28 | 2,597 | largest |
| `preclinical/anesthetics` (+ `ingredients`, `examination_anesthetics`) | 25 | 2,342 | |
| `preclinical/extra_data` (+ `bloodgas_data`, `physiological_data`) | 20 | 1,638 | only package with `@Transactional` services |
| `preclinical/therapies` (+ `subject_therapies`) | 19 | 1,691 | |
| `preclinical/subjects` (`controller`/`dto`/`model`/`repository`/`service`) | 18 | 1,766 | only package with a layered sub-structure |
| `preclinical/references` | 15 | 1,209 | |
| `preclinical/contrast_agent` | 8 | 896 | |
| `shared` (`controller`, `error`, `exception`, `validation`) | 9 | 600 | partially duplicates ms-common |
| `api` | 4 | 225 | swagger-codegen fossils, see §7 |
| `configuration` (`amqp`, `security`) | 2 | 211 | |
| `preclinical/bruker` | 2 | 335 | |
| root (`ShanoirPreclinicalApplication`, `RFC3339DateFormat`) | 2 | — | |

### 3.2 Layering

Each domain concept follows a rigid 8-class template: `XApi` (interface holding all Spring MVC + OpenAPI annotations) → `XApiController` (`@Controller implements XApi`) → `XService` → `XServiceImpl` → `XRepository` (+ optional `XRepositoryCustom`/`XRepositoryImpl`) → entity → `XUniqueValidator` → `XEditableByManager`. Only `subjects` uses a DTO layer; every other package **serialises JPA entities directly over HTTP** in both directions.

This layering is inherited from swagger-codegen, not designed. The `api` package still contains generator output (`ApiException`, `NotFoundException`, `ApiOriginFilter`, `Error`) that nothing references.

### 3.3 JPA entity model

```
Reference(id, category, reftype, refvalue)          <-- untyped, no @Table, no unique constraint
   ^  ^  ^  ^  ^ (5x @ManyToOne)
AnimalSubject(id = studies.subject.id)              <-- @Id, no @GeneratedValue, cross-DB implicit FK
   |-- 1:N SubjectPathology  --> Pathology, PathologyModel, Reference(location)
   |-- 1:N SubjectTherapy    --> Therapy, Reference(doseUnit)
Pathology(id, name @Unique)
PathologyModel(id, name @Unique, pathology, filename, filepath)
Therapy(id, name @Unique, therapyType)
Anesthetic(id, name, anestheticType) -- 1:N AnestheticIngredient --> Reference(name, concentrationUnit)
ExaminationAnesthetic(id, examinationId*, anesthetic, dose, ...)     * FK into datasets, unvalidated
ContrastAgent(id, protocolId*, name, ...)                            * FK elsewhere, unvalidated
ExaminationExtraData(id, examinationId*, filename, filepath, extradatatype)   single-table hierarchy
   +-- PhysiologicalData, BloodGasData
```

Notable model facts:

- **`AnimalSubject.id` is a foreign key into another microservice's database** with no `@MapsId`, no FK constraint, and no way to enforce integrity. Migration `docker-compose/database-migrations/db-changes/preclinical/0004_sync_subject_ids.sql` performed this collapse by shifting ids by 1,000,000 — a technique that silently corrupts data if any id ≥ 1,000,000 already exists.
- **No `unique = true` or `@UniqueConstraint` anywhere** in the module. Uniqueness is enforced only by an application-level read-then-write (§9.7).
- `@ManyToOne` defaults to `EAGER`, so loading a `SubjectPathology` always joins `animal_subject`, `pathology`, `pathology_model` and `reference` (§11).

### 3.4 DB schema owned

Database `preclinical` (MariaDB), created by `docker-compose/database/1_create_databases.sh:26`. `ddl-auto: validate` in prod (`application.yml:42`), `create` in dev, `create-drop` in test. Migrations live in `docker-compose/database-migrations/db-changes/preclinical/0001…0005`.

> **On the `.gitignore` hint:** `docker-compose/database/3_init_preclinical.sql` is gitignored (`.gitignore:25`) but **does not exist and has no git history** — the database is created by `1_create_databases.sh` alongside every other schema. The entry is dead cruft. The `null*` / `nullbruker/` entries (`.gitignore:27,38`) are a *real* bug fossil; see §6.4.

---

## 4. External interfaces

### 4.1 REST API

Public prefix `/shanoir-ng/preclinical/` → `http://shanoir-ng-preclinical:9900/` (`shanoir-ng-nginx/files/etc/nginx/nginx.conf:129`).

**Every endpoint below is `authenticated()` only, unless an auth column entry says otherwise.**

| Method | Path | Auth | Purpose | Declared at |
|---|---|---|---|---|
| POST | `/subject` | — | Create animal subject (+ remote clinical subject) | `AnimalSubjectApi.java:48` |
| GET | `/subject/{id}` | — | Get animal subject | `AnimalSubjectApi.java:59` |
| POST | `/subject/find?ids=` | — | Bulk fetch by subject ids | `AnimalSubjectApi.java:69` |
| PUT | `/subject/{id}` | — | Update animal subject | `AnimalSubjectApi.java:79` |
| POST/DELETE/GET/GET/PUT | `/subject/{id}/pathology`, `/{pid}`, `/all` | — | Subject pathologies CRUD | `SubjectPathologyApi.java:42,53,64,75,86` |
| GET | `/subject/all/pathology/{pid}` | — | Reverse lookup by pathology | `SubjectPathologyApi.java:95` |
| GET | `/subject/all/pathology/model/{pathoModelId}/` | — | Reverse lookup by model — **note trailing slash** (§9.12) | `SubjectPathologyApi.java:105` |
| PUT | `/subject/{id}/pathology/{pid}` | — | Update subject pathology | `SubjectPathologyApi.java:115` |
| POST/DELETE/DELETE/GET/GET/GET/PUT | `/subject/{id}/therapy…`, `/subject/all/therapy/{tid}` | — | Subject therapies CRUD | `SubjectTherapyApi.java:43,54,65,75,86,94,103` |
| POST/DELETE/GET/GET/GET/PUT | `/therapy`, `/therapy/{id}`, `/therapy/type/{type}` | — | Therapy master data | `TherapyApi.java:45,56,65,73,81,91` |
| POST/DELETE/GET/GET/PUT | `/pathology`, `/pathology/{id}` | — | Pathology master data | `PathologyApi.java:45,56,65,73,83` |
| POST/DELETE/GET/GET/GET/PUT | `/pathology/model…`, `/pathology/{id}/model/all` | — | Pathology models | `PathologyModelApi.java:50,61,70,78,86,96` |
| POST | `/pathology/model/upload/specs/{id}` | — | Upload model spec file | `PathologyModelApi.java:108` |
| GET | `/pathology/model/download/specs/{id}` | — | Download model spec file | `PathologyModelApi.java:119` |
| GET | `/pathology/model/files` | **`hasRole('ADMIN')`** | Admin file inventory | `PathologyModelApi.java:129-130` |
| POST/DELETE/GET/GET/GET/PUT | `/anesthetic…` | — | Anaesthetic master data | `AnestheticApi.java:45,56,65,73,81,91` |
| POST/DELETE/GET/GET/PUT | `/anesthetic/{id}/ingredient…` | — | Ingredients | `AnestheticIngredientApi.java:46,59,69,80,90` |
| POST/DELETE/GET/GET/PUT/GET | `/examination/{id}/anesthetic…`, `/examination/all/anesthetic/{id}` | — | Examination anaesthetics | `ExaminationAnestheticApi.java:43,54,66,77,88,100` |
| POST/DELETE/GET/GET/GET/GET/PUT | `/protocol/{pid}/contrastagent…` | — | Contrast agents | `ContrastAgentApi.java:45,57,67,76,86,95,105` |
| POST | `/examination/extradata/upload/{id}` | — | Upload extra-data file | `ExtraDataApi.java:55` |
| POST | `/examination/{id}/extradata` \| `/physiologicaldata` \| `/bloodgasdata` | — | Create extra data | `ExtraDataApi.java:67,80,93` |
| DELETE/GET/GET | `/examination/{id}/extradata…` | — | Extra-data CRUD | `ExtraDataApi.java:104,116,126` |
| GET | `/examination/extradata/download/{id}` | — | Download attachment | `ExtraDataApi.java:136` |
| PUT | `/examination/{id}/physiologicaldata/{eid}` \| `/bloodgasdata/{eid}` | — | Update | `ExtraDataApi.java:147,160` |
| GET | `/examination/extradata/files` | **`hasRole('ADMIN')`** | Admin file inventory | `ExtraDataApi.java:174-175` |
| POST/DELETE/GET×6/PUT | `/refs…` | — | **Global reference catalogue CRUD** | `RefsApi.java:43,53,62,71,81,87,95,102,110,122` |
| POST | `/bruker/upload` | — | Bruker archive upload + conversion | `BrukerApi.java:37` |

`/swagger-ui.html`, `/swagger-ui/**`, `/api-docs/**` are `permitAll()` (`SecurityConfiguration.java:75-76`).

### 4.2 RabbitMQ

**Consumed (inbound listeners):**

| Queue | Payload | Producer | Handler |
|---|---|---|---|
| `delete-animal-subject-queue` | subject id as plain `String` | `shanoir-ng-studies/.../SubjectServiceImpl.java:135` | `RabbitMQPreclinicalService.java:59` |
| `copy-animal-subject-queue` | JSON `{"sourceId":n,"targetId":m}` | `shanoir-ng-studies/.../RelatedDatasetServiceImpl.java:216` | `RabbitMQPreclinicalService.java:86` |

Both listeners use the **default** container factory (no `containerFactory` attribute), unlike studies/nifti-conversion which name `multipleConsumersFactory`/`singleConsumerFactory` (`shanoir-ng-ms-common/.../RabbitMQConfiguration.java:41,54`). Neither queue has a dead-letter exchange — `RabbitMQConfiguration` declares every queue as a bare `new Queue(name, true)` with no `x-dead-letter-*` arguments, and both handlers throw `AmqpRejectAndDontRequeueException`, so **failed deletes and copies are silently discarded**.

**Published (synchronous RPC via `convertSendAndReceive`):**

| Queue | Request | Reply | Consumer | Call site |
|---|---|---|---|---|
| `bruker-conversion-queue` | `"<srcAbsPath>;<dstAbsPath>"` | `Boolean` | `shanoir-ng-nifti-conversion/.../RabbitMqNiftiConversionService.java:49` | `BrukerApiController.java:139` |
| `subjects-name-queue` | JSON `IdName{id=studyId,name}` | `Boolean` | `shanoir-ng-studies/.../RabbitMQSubjectService.java:121` | `AnimalSubjectServiceImpl.java:150` |
| `subjects-queue-with-datasets` | JSON `SubjectDto` | `Long` (new subject id) | `shanoir-ng-studies/.../RabbitMQSubjectService.java:135` | `AnimalSubjectServiceImpl.java:155` |

**Published (fire-and-forget, topic exchange `events-exchange` via `ShanoirEventService`, routing key = event type):**
`CREATE|UPDATE_PRECLINICAL_SUBJECT_EVENT`, `CREATE|UPDATE|DELETE_PRECLINICAL_REFERENCE_EVENT`, `CREATE|UPDATE|DELETE_PATHOLOGY_EVENT`, `CREATE|UPDATE|DELETE_THERAPY_EVENT`, `CREATE|UPDATE|DELETE_ANESTHETIC_EVENT` (14 distinct types; `ShanoirEventService.java:60`). Consumed by `users`, `studies` and `datasets`.

> **Correction to a common assumption:** `anima-conversion-queue` is **not** used by this service. Its only producer is `shanoir-ng-import/.../ImporterApiController.java:486`.

### 4.3 Outbound HTTP

**None.** All cross-service calls are AMQP. The service holds no `RestTemplate`, `WebClient` or Feign client.

Inbound HTTP callers observed: the Angular frontend only (`shanoir-ng-front/src/app/preclinical/**`). No other backend service calls preclinical over HTTP.

### 4.4 Filesystem & external process touchpoints

- `storage.file-system.uploadBrukerFolder: /tmp/` (`application.yml:113`) → the service writes `/tmp/bruker/convert/<uploadedFileName>/<n>/` (`BrukerApiController.java:154-163`). `/tmp` is a **docker volume shared with `import`, `studies`, `datasets` and `nifti-conversion`** (`docker-compose.yml:186,217,267,307,338`).
- `storage.file-system.preclinical-data: /var/preclinical-data` (persistent volume) via the shared `StorageService` from `shanoir-ng-storage` — pathology-model specs and extra-data attachments. An S3 backend is selectable via `SHANOIR_STORAGE_TYPE`.
- **No process is forked by this service.** `dicomifier` is executed in the `nifti-conversion` container (`shanoir-ng-nifti-conversion/.../ShanoirExec.java:339-352`), reached over AMQP.
- `spring.servlet.multipart.max-file-size: -1` and `max-request-size: -1` (`application.yml:77-78`) — uploads are **unbounded**.

### 4.5 Shared code from `ms-common` / `storage`

`shanoir-ng-ms-common` (33 distinct types) and `shanoir-ng-storage` (`pom.xml:35-43`):

`RabbitMQConfiguration` · `AbstractEntityInterface` · `IdName` · `LocalDateSerializer` · `FileEntryDTO` · `FieldError` · `FieldErrorMap` · `ShanoirEvent` · `ShanoirEventService` · `ShanoirEventType` · `ErrorDetails` · `ErrorModel` · `RestServiceException` · `ShanoirException` · `HalEntity` · `Links` · `FieldEditionSecurityManagerImpl` · `SubjectType` · `RefValueExists` · `RefValueExistsValidator` · `Unique` · `UniqueConstraintManagerImpl` · `StorageException` · `StorageService` · `KeycloakUtil` · `MDCFilter` · `SecurityContextUtil` · `Utils`.

Two of these are **misplaced**: `RefValueExists` and `RefValueExistsValidator` live in `ms-common` but `RefValueExistsValidator` imports `org.shanoir.ng.preclinical.references.Reference` and `RefsService` — a shared library depending on a leaf service's package. Notably, this file physically resides at `shanoir-ng-preclinical/src/main/java/org/shanoir/ng/shared/validation/RefValueExistsValidator.java`, i.e. the service **shadows the `org.shanoir.ng.shared` package** of the library it depends on. The same shadowing applies to `shared/controller/GlobalExceptionHandler`, `shared/error/FieldError(Map)` and `shared/exception/*`, which duplicate ms-common types under identical FQNs — classpath-order-dependent and a latent source of confusion.

---

## 5. Duplication vs the clinical path (studies / datasets)

### 5.1 Side-by-side mapping

| Preclinical | Clinical counterpart | Relationship |
|---|---|---|
| `AnimalSubject` (`subjects/model`) | `Subject` (studies) + `Subject.preclinical` | **Extension**, shared PK. Not duplication. |
| — | `Examination` + `Examination.preclinical` (datasets) | Animal examinations live entirely in datasets. |
| `ExaminationExtraData` / `PhysiologicalData` / `BloodGasData` | `DatasetFile` / examination attachments (datasets) | Parallel, independent file-attachment implementation. |
| `Reference` (`category`/`reftype`/`refvalue`) | typed enums + dedicated tables (studies) | Divergent modelling of the same problem. |
| `BrukerApiController.uploadBrukerFile` | `ImporterApiController.uploadDicomZipFile` | Parallel upload/unzip/validate pipelines. |
| `RefsApiController` | `CenterApi`, `AcquisitionEquipmentApi` (studies) | Both are master-data CRUD; only studies is access-controlled. |
| `shared/exception/*`, `shared/error/*`, `shared/controller/GlobalExceptionHandler` | identical FQNs in ms-common | Direct file-level duplication. |

**The domain split itself is sound.** `AnimalSubject` genuinely is a 5-column extension of `Subject`, and animal examinations correctly reuse the datasets `Examination`. The duplication problem is not the domain model — it is the **scaffolding**.

### 5.2 Quantified duplication

*Internal* (measured by normalising entity names then intersecting non-comment lines):

| Pair | Lines | Identical after normalisation |
|---|---|---|
| `TherapyApiController` vs `AnestheticApiController` | 138 / 138 | **127 (92 %)** |
| `TherapyApiController` vs `PathologyApiController` | 138 / 115 | **111 (97 % of the smaller)** |
| `TherapyServiceImpl` vs `PathologyServiceImpl` | 72 / 75 | **62 (86 %)** |
| `TherapyServiceTest` vs `PathologyServiceTest` | 99 / 88 | **73 (83 %)** |

Eleven entities × the 8-class template ≈ **8,000–9,000 LOC (~45 % of the module) is mechanically-derivable boilerplate**, of which the 25 validator classes (~570 LOC) are 88 % inert (§7.1).

*Versus the clinical path:* the genuine cross-service duplication is smaller than it looks — roughly 600 LOC of `shared/` classes duplicating ms-common, plus the parallel upload/unzip/attachment machinery (~700 LOC across `BrukerApiController`, `ExtraDataApiController`, `PathologyModelApiController`).

### 5.3 Divergences — fixes applied on one side only

1. **Study-user rights.** Studies and datasets enforce `@studySecurityService.hasRightOnSubjectForOneStudy(...)` per endpoint (`shanoir-ng-studies/.../SubjectApi.java:59,131,146,160,184`). Preclinical has no such mechanism and does not even depend on `shanoir-ng-study-rights`. Every rights fix made on the clinical side over the years has bypassed this service.
2. **AMQP reply timeout.** Studies sets `reply-timeout: 60000` (`application.yml:77`); datasets bumps to 300 s for downloads (`DatasetDownloaderServiceImpl.java:116`). Preclinical never configures it and still issues a long-running RPC on the default 5 s (§9.2).
3. **`@EditableOnlyBy`.** Studies actually annotates fields (`Study.java:111`, `Center.java:73`). Preclinical inherited the framework and never used it.
4. **DTO layer.** Studies/datasets use MapStruct mappers; preclinical serialises entities directly except for `AnimalSubject`, whose DTO service is hand-written (`AnimalSubjectDtoService.java`).
5. **`CopyRequest` wire contract is defined twice** — as a local record *inside a method* at `shanoir-ng-studies/.../RelatedDatasetServiceImpl.java:216` and again at `RabbitMQPreclinicalService.java:53`. Changing one silently breaks the other.

### 5.4 Recommendation: **extract a shared module; do not merge**

Merging preclinical into studies/datasets would mean merging two databases with a cross-DB shared PK, and would drag the animal domain into services that are already the two largest in the platform (68.7k and 28.1k LOC). The domain boundary is defensible.

Instead:

1. **Add `shanoir-ng-study-rights` as a dependency and wire `@PreAuthorize` per endpoint** — mandatory, and independent of any refactor (§13).
2. **Delete the shadowing `org.shanoir.ng.shared.*` classes** in this module and use ms-common's; move `RefValueExists*` out of ms-common into preclinical where it belongs.
3. **Extract an `AbstractCrudApiController<T>` / `AbstractCrudServiceImpl<T>` pair** into ms-common. Eleven entities collapsing onto one base would remove ~4,000 LOC of main code and ~2,000 of test code.
4. **Delete the 22 inert validators**, and add real DB unique constraints.

Trade-offs: (1) and (2) are pure wins. (3) trades a large, mechanical, well-tested-by-construction refactor against a permanent reduction in duplication — worth it precisely *because* the copies have already drifted (§9.5). (4) changes error codes from 422 to 409 for duplicate names, which the frontend must handle.

---

## 6. Bruker / Anima conversion pipeline deep-dive

### 6.1 How it works

1. Browser posts a `.zip` to `POST /bruker/upload` (`BrukerApi.java:37`).
2. `BrukerApiController.uploadBrukerFile` strips `.zip` from the client filename (`:81-84`) and creates `/tmp/bruker/convert/<name>/<n>/` (`:86`, `createBrukerTempFile` `:152-165`).
3. The multipart file is written into that folder using the **raw client filename** (`saveUploadedFileTmp` `:175-181`).
4. The archive is unzipped in place (`unzipBrukerArchive` `:190-208`).
5. The tree is crawled for a `2dseq` file to decide validity (`checkBrukerCrawlFor2dseq` `:234-245`).
6. If valid: an AMQP RPC `"<src>;<dst>"` is sent to `bruker-conversion-queue` (`:133-143`).
7. `nifti-conversion` receives it (`RabbitMqNiftiConversionService.java:49-62`) and shells out to `dicomifier` (`NIfTIConverterService.java:68-69` → `ShanoirExec.dicomifier` `:339-352`), reading and writing through the **shared `/tmp` volume**.
8. On success, the controller zips the `result/` folder (`:104-106`) and returns the **absolute server path** of the zip as a plain-text 200 body (`:107`).
9. The browser posts that path back to `POST /importer/import_dicom/` (`shanoir-ng-front/.../bruker-upload.component.ts:90`), which reads and deletes it.

### 6.2 External dependencies

`dicomifier` (a Python DICOM/Bruker toolchain) inside the `nifti-conversion` image; its path comes from `NiftiConverter.DICOMIFIER.getPath()`.

### 6.3 Failure modes

| # | Failure | Evidence |
|---|---|---|
| F1 | **5 s RPC timeout → NPE.** `convertSendAndReceive` returns `null` past the default `RabbitTemplate.DEFAULT_REPLY_TIMEOUT` (5,000 ms); `(boolean) null` throws NPE, caught by the catch-all at `:119` and reported as "Error while saving uploaded file". A real Bruker study conversion takes minutes. | `BrukerApiController.java:139` |
| F2 | **No process timeout on the converter side.** `proc.waitFor()` has no timeout, so a hung `dicomifier` pins a consumer thread forever. | `ShanoirExec.java:295` |
| F3 | **Argument injection.** `execString` is built by string concatenation and then `split(" ")`. The path contains the client-supplied filename, so a file named `x --flag y.zip` injects extra argv entries into `dicomifier`. Not shell injection (`Runtime.exec(String[])`, no shell), but attacker-controlled argv. | `ShanoirExec.java:345,347` |
| F4 | **Zip Slip.** `filePath = brukerDirPath + "/" + entry.getName()` with no normalisation/containment check → an entry named `../../../../etc/x` escapes the extraction root onto the shared volume. | `BrukerApiController.java:195,198` |
| F5 | **Path traversal on the upload filename.** `getOriginalFilename()` is used unsanitised in `Paths.get(...)` at both `:86` (via `fileName`) and `:177`. | `BrukerApiController.java:80,177` |
| F6 | **Result zip lands in the wrong directory.** `File.createTempFile(destinationFilePath, …)` is called with an *absolute path* as the prefix. **Verified empirically on JDK 25:** it does not throw — the JDK reduces the prefix to its last path segment, so the file is created in `java.io.tmpdir` (`/tmp/result<random>.<n>.converted.zip`) instead of the intended `<brukerDir>/result`. The intended location is silently ignored. | `BrukerApiController.java:104` |
| F7 | **Unbounded, never-cleaned disk growth.** Nothing deletes `/tmp/bruker/convert/**`, and the misplaced result zips accumulate in `/tmp` root. Combined with unlimited multipart size (`application.yml:77-78`), any authenticated user can fill the shared volume, taking down `import`, `datasets`, `studies` and `nifti-conversion` with it. | — |
| F8 | **Resource leak.** `zipFolder` opens `FileOutputStream`/`ZipOutputStream` without try-with-resources or `finally`; any exception from `addFolderToZip` leaks both handles. | `BrukerApiController.java:247-257` |
| F9 | **`NullPointerException` on a missing filename.** `fileName.toLowerCase()` with no null check. | `BrukerApiController.java:80-81` |
| F10 | **`NullPointerException` on an empty directory.** `Arrays.asList(new File(...).listFiles())` — `listFiles()` returns `null` if the path is not a readable directory; also recursively at `:238`. | `BrukerApiController.java:95,238` |
| F11 | **TOCTOU on the working directory.** `createBrukerTempFile` probes `exists()` then `createDirectories()` non-atomically; two concurrent uploads of the same filename can collide. The loop also wastes its first iteration (it re-assigns index 0 before incrementing). | `BrukerApiController.java:152-165` |
| F12 | **`logs.concat(execString)` discards its result** (twice) — `String` is immutable, so the command is never actually logged. | `ShanoirExec.java:346,369` |

### 6.4 The `null*` directory issue — resolved

`.gitignore:27,38` carry `shanoir-ng-preclinical/null*` and `shanoir-ng-preclinical/nullbruker/`. Full provenance:

- **Origin:** the upload folder used to come from a `ShanoirPreclinicalConfiguration` bean that tests replaced with `@MockBean`. The mock returned `null`, so `null + "bruker" + "/" + "convert" + …` produced the **relative** path `nullbruker/convert/…`, created in the module working directory. Hence the ignore entries (added in `9b5a36753`).
- **2020 fix** (`24f3a11f9`, "Shanoir-issue#672 Useless file created while launching preclinical tests"): replaced the config bean with `@Value` and set the property from a **static JUnit 4 `@BeforeClass`** guarded by `@ClassRule TemporaryFolder` — which ran before the Spring context, so the override worked.
- **Regression** (`3accad469`, "Fixes for: BeforeAll is not static"): the JUnit 5 migration converted that to a **non-static `@BeforeEach`** — the method is *still named `beforeClass`* (`BrukerApiControllerTest.java:67-68`). `@BeforeEach` runs *after* the context is built, so `System.setProperty` at `:70` has no effect and `@TempDir tempFolder` is never used by the code under test.
- **Current behaviour:** `brukerFolder` resolves from `application.yml:113` to `/tmp/`, so the tests now create and leave behind real `/tmp/bruker/convert/2dseq/0/` and `/tmp/bruker/convert/filename/0/` directories on every developer machine and CI runner. The literal `nullbruker` directory no longer appears, but the underlying "tests write to a real shared path" defect was never fixed — it moved.

**Fix:** use `@DynamicPropertySource` (static) or `@TestPropertySource(properties = "storage.file-system.uploadBrukerFolder=…")`, and delete the stale `.gitignore` entries.

---

## 7. Code quality assessment

### 7.1 Validation theatre (the dominant theme)

- **Zero `@EditableOnlyBy` annotations exist in the module.** `FieldEditionSecurityManagerImpl.validate` iterates declared fields looking only for that annotation (`shanoir-ng-ms-common/.../FieldEditionSecurityManagerImpl.java:58-88`), so all **12** `*EditableByManager` subclasses (280 LOC of empty class bodies) always return an empty `FieldErrorMap`. Every `getCreationRightsErrors`/`getUpdateRightsErrors` call — 22 call sites across 11 controllers — is a no-op.
- **Only 3 entities carry `@Unique`** (`Therapy.java:42`, `Pathology.java:39`, `PathologyModel.java:44`), so **10 of the 13** `*UniqueValidator`/`*UniqueConstraintManager` classes are likewise inert — including `AnimalSubjectUniqueValidator` (`src/.../subjects/service/AnimalSubjectUniqueValidator.java:22`, a one-line empty class).
- **`RefValueExistsValidator` is a no-op for `AnimalSubject`.** `AnimalSubjectApiController.java:133` instantiates it per request, but `AnimalSubject` carries no `@RefValueExists` on any field (`AnimalSubject.java:49-62`), so it validates nothing. Meanwhile 5 of the 8 `@RefValueExists` annotations that do exist are **commented out** (`SubjectTherapy.java:63`, `ExaminationAnesthetic.java:50`, `ContrastAgent.java:47,55,61`).

Net: **22 of 25 validator classes are provably dead**, plus a dead validator invocation on the most important entity.

### 7.2 Reference-data model: stringly-typed and reflectively coupled

`Reference` is `(category, reftype, refvalue)`, all `String`, with `category` defaulting to `"common"` (`Reference.java:36-44`). `ReferenceEnum` — the one place where these strings could be centralised — defines exactly **two** constants (`ReferenceEnum.java:23-24`); everything else is a raw literal in SQL seed data or the frontend.

The worst coupling is in `RefValueExistsValidator.java:70`:

```java
Optional<Reference> foundValue = service.findByTypeAndValue(field.getName(), value.getValue());
```

The **Java field name is used as the database `reftype`**. Renaming `specie` → `species` in the entity silently breaks validation at runtime with no compile error. `category` is ignored entirely, so a value registered under any category satisfies the check.

Additionally, `Reference.equals`/`hashCode` compare only `reftype` and `value` — **excluding `category` and `id`** (`Reference.java:117-132`). Two references from different categories, or two distinct DB rows, are "equal". Any `Set<Reference>` or `Map` keyed on references collapses them.

`Reference` has no `@Table` annotation (relying on the default name), no unique constraint, and `RefsApiController.deleteReferenceValue` (`:84-98`) deletes without checking whether the reference is still in use by any subject, pathology or ingredient — the delete will either fail with a raw FK violation surfaced as a 500, or orphan data.

### 7.3 Entity design defects

| Issue | Location |
|---|---|
| `equals` includes two LAZY collections; `hashCode` excludes them. Calling `equals` on a detached instance triggers lazy loading or `LazyInitializationException`. | `AnimalSubject.java:191-203` |
| `equals` contains a literal duplicate clause: `Objects.equals(this.getId(), subject.getId()) && Objects.equals(this.id, subject.id)`. | `AnimalSubject.java:191-192` |
| Contradictory Jackson annotations on one field: `@JsonIgnore` + `@JsonProperty("animalSubject")` + `@JsonManagedReference`. `@JsonIgnore` wins; the other two are dead. | `SubjectPathology.java:51-53` |
| JPA/validation annotations duplicated on **both** the field and its getter (`@JsonProperty`, `@ManyToOne`, `@NotNull`). Hibernate uses field access here, so the getter copies are silently ignored. | `SubjectPathology.java:61-64` vs `:110-113` |
| `@PostLoad initLinks()` dereferences `getAnimalSubject().getId()` — NPE if the association is null, and it forces the association on every single load. | `SubjectPathology.java:91-94` |
| `@Id` with no `@GeneratedValue`; the id is a cross-database FK assigned by hand. | `AnimalSubject.java:46-47` |

### 7.4 Error handling

- **Swallow-and-continue.** `saveUploadedFile` catches `Exception`, logs, and returns `null` — twice, in two copy-pasted variants that then behave *differently* (§9.5). | `ExtraDataApiController.java:368-372`, `PathologyModelApiController.java:275-279` |
- **Silent 200 on download failure.** `downloadExtraData` catches `IOException`, logs it, and falls through — the client gets a 200 with a truncated or empty body. | `ExtraDataApiController.java:275-277` |
- **Try/catch around a plain setter**, with a log message about "parsing subject id for Long cast" that has nothing to do with the code. A copy-paste fossil. | `SubjectTherapyApiController.java:85-89` |
- **Format-string placeholder inside an error message returned to the client:** `"Error while converting bruker files to dicom files: {}"` is passed as an `ErrorModel` message, not a log template. | `BrukerApiController.java:114` |
- **String concatenation in log calls** instead of SLF4J placeholders, in ~15 places (e.g. `ExtraDataApiController.java:219-220`, `PathologyModelApiController.java:118-119,186`).

### 7.5 Dead code

- `api/` package: `ApiException`, `NotFoundException`, `ApiOriginFilter`, `Error` (225 LOC) — swagger-codegen output, unreferenced.
- Unused `@Autowired RabbitTemplate` fields: `RefsServiceImpl.java:44`, `SubjectPathologyServiceImpl.java:47`.
- `PathologyServiceImpl.updateFromShanoirOld` (`:106-124`) — `return true;` followed by 15 lines of commented-out Shanoir-1 code referencing a `RabbitMqConfiguration` class that no longer exists.
- `AnimalSubjectRepositoryImpl.findByReference` and its service/interface wrappers — **no production caller**; referenced only from tests.
- Commented-out test methods: `TherapyServiceTest.java:128-136`, `PathologyServiceTest.java:107-125`.
- **A 4 MB test log committed to git** since 2018: `shanoir-ng-preclinical/shanoir-ng-preclinical.log` (4,055,723 bytes, added in `b759e8c07`, dated 2018-05-03→2018-05-22). It contains no credentials, but it is 4 MB of noise in every clone.
- **Zero `TODO`/`FIXME`/`XXX`/`HACK` markers** in the entire module — not a sign of cleanliness, but of dead code being left as comment blocks instead of being tracked.

### 7.6 Configuration smells

`spring.main.allow-circular-references: true` in all three profiles (`application.yml:52,138,165`) — masks a real bean-graph problem. Hard-coded DB credentials `username: preclinical / password: password` (`:34-35`). `SHANOIR_STORAGE_TYPE` gates S3 but `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` are declared with no default (`:30-31`), so a file-system deployment still fails to start if they are unset.

---

## 8. Test coverage analysis

### 8.1 Numbers

| Metric | Value |
|---|---|
| Test source files | 58 |
| — `*Test.java` (**run** by surefire) | 37 |
| — `*TestIT.java` (**never run**) | 13 |
| — helpers (`*ModelUtil`, `TestConfiguration`, `KeycloakControllerTestIT`) | 8 |
| `@Test` methods in `*Test.java` | **212** |
| `@Test` methods in `*TestIT.java` | 112 (dead) |
| Test LOC | ~6,250 |
| Main classes | 152 |

Surefire is declared with no configuration (`shanoir-ng-back/pom.xml:236-238`), so its default includes apply: `**/Test*.java`, `**/*Test.java`, `**/*Tests.java`, `**/*TestCase.java`. **`*TestIT.java` matches none of them**, and no failsafe plugin is configured. CI runs `mvn install` without `-DskipTests` (`.github/workflows/maven.yml:55`), so the 37 `*Test.java` classes do execute — and the 13 IT classes have been silently skipped for years. They still assert `HttpStatus.FOUND` for unauthenticated requests (`TherapyApiControllerTestIT.java:57,72,87,102,120`), which was correct for the old Keycloak adapter but is `401` under the current OAuth2 resource-server configuration. They also require `@ActiveProfiles("dev")` (a live MariaDB) and a live Keycloak.

### 8.2 Per-package coverage map

| Package | Tested | Notes |
|---|---|---|
| `therapies` | partial | 8 classes / 1,082 LOC |
| `pathologies` | partial | 12 classes / 1,582 LOC |
| `anesthetics` | partial | 12 classes / 1,436 LOC |
| `references` | partial | 4 classes / 507 LOC |
| `subjects` | partial | 4 classes / 503 LOC |
| `contrast_agent` | partial | 4 classes / 483 LOC |
| `extra_data` | partial | 4 classes / 571 LOC |
| `bruker` | **1 class, 2 tests, both trivial** | 93 LOC |
| **`configuration/amqp`** (`RabbitMQPreclinicalService`) | **ZERO** | both inbound queue handlers untested |
| **`configuration/security`** | **ZERO** | |
| **`subjects/dto`** (`AnimalSubjectDtoService`, 152 LOC) | **ZERO** | the only real mapping logic in the module |
| **`shared/validation`** (`RefValueExistsValidator`) | **ZERO** | |
| **`shared/controller`** (`GlobalExceptionHandler`) | **ZERO** | |
| **`api/`** | **ZERO** | (dead code) |
| **All 12 `*EditableByManager`** | **ZERO** | |
| **`extra_data/{bloodgas,physiological}` service impls** | **ZERO** direct | |

### 8.3 Quality critique — blunt

**The 58-class count is the most misleading metric in the backend.** Concretely:

1. **They are templates.** After normalising entity names, `TherapyServiceTest` and `PathologyServiceTest` share **73 of 88 lines (83 %)**. The same holds across all 12 `*ServiceTest` and 13 `*ApiControllerTest` classes. `TherapyServiceTest.java:128-136` even contains a commented-out test that still references `pathologiesService` — proof it was copied from the pathology file.

2. **They assert Mockito, not behaviour.** The dominant shape is: stub the repository to return `X`, call the service, assert the result is `X`, then `verify(repo, times(1))`. Example — `TherapyServiceTest.java:76-82`:
   ```java
   given(therapiesRepository.findAll()).willReturn(Arrays.asList(createTherapyBrain()));  // setup
   final List<Therapy> therapies = therapiesService.findAll();
   Assertions.assertTrue(therapies.size() == 1);            // asserts the stub
   Mockito.verify(therapiesRepository, times(1)).findAll();  // asserts delegation
   ```
   This can only fail if someone deletes the delegating method.

3. **`@SpringBootTest` used for pure Mockito tests.** All 12 `*ServiceTest` classes are annotated `@SpringBootTest` (e.g. `TherapyServiceTest.java:41`) while using only `@Mock`/`@InjectMocks`. The full application context — H2, JPA, every bean — is booted and then completely ignored. (The mocks *are* initialised, via Spring's `MockitoTestExecutionListener`, so these tests do run; the problem is cost and misleading scope, not correctness.)

4. **Security is switched off in every controller test.** All 13 use `@AutoConfigureMockMvc(addFilters = false)` (e.g. `AnimalSubjectApiControllerTest.java:67`). `@WithMockKeycloakUser(... "ROLE_ADMIN")` at `:140,149` is decorative. **No test in the module verifies authentication or authorization** — which is precisely why the gap in §10 went unnoticed.

5. **Almost no negative paths.** Assertions are overwhelmingly `status().isOk()` with no body checks. There are essentially no tests for 404s, 422 validation failures, null inputs, or exception mapping.

6. **The Bruker pipeline is effectively untested.** Two tests (`BrukerApiControllerTest.java:75,86`): one uploads a file literally named `2dseq` (so the crawl trivially succeeds without any real Bruker structure) and asserts 200; the other uploads `filename.txt` and asserts 406. Neither exercises unzipping, the AMQP payload format, the result zip, or any failure mode — and, per §6.4, the first one writes to the real `/tmp`.

7. **Sloppiness inside the tests.** `AnimalSubjectApiControllerTest.setup()` stubs `getById(ID)` three times with different values (`:110`, `:113`, `:119`); only the last survives.

### 8.4 Prioritised missing tests

1. **Authorization tests** mirroring `shanoir-ng-datasets/src/test/java/.../DatasetApiSecurityTest.java` — must come with the fix in §13.
2. `RabbitMQPreclinicalService` — both handlers, including idempotency (redelivery) and the null-subject path.
3. `BrukerApiController` — Zip Slip rejection, traversal filenames, RPC timeout/`null` reply, missing `2dseq`, cleanup.
4. `AnimalSubjectDtoService` — round-trip fidelity, especially the pathology asymmetry (§9.6).
5. `AnimalSubjectApiController.createAnimalSubject` — the compensating path when the remote subject is created but the local save fails (§9.3).
6. IDOR tests: child resource under the wrong parent must 404.
7. Convert the 13 IT classes to Testcontainers, or delete them.

---

## 9. Bugs & correctness risks

| ID | Severity | Summary | Location |
|---|---|---|---|
| B1 | **Critical** | Unauthorized arbitrary file read + delete via `/importer/import_dicom/`, driven by the preclinical Bruker flow | `shanoir-ng-import/.../ImporterApi.java:132`; `ImporterApiController.java:374-387` |
| B2 | **Critical** | Zip Slip in Bruker upload | `BrukerApiController.java:195,198` |
| B3 | **Critical** | No study-user rights enforcement anywhere in the service | §10.1 |
| B4 | **High** | Bruker RPC: 5 s default timeout + `(boolean)` unboxing of a `null` reply | `BrukerApiController.java:139` |
| B5 | **High** | IDOR on all nested resources | `SubjectTherapyApiController.java:110,148`; `SubjectPathologyApiController.java:106,148`; `ExaminationAnestheticApiController.java:107` |
| B6 | **High** | Distributed-transaction gap: remote subject created, local save fails, no compensation | `AnimalSubjectApiController.java:87-91` |
| B7 | **High** | Upload failures return HTTP 200 with wrong/`null` body | `ExtraDataApiController.java:106-111`; `PathologyModelApiController.java:211-215` |
| B8 | **High** | `findById(...).orElse(null)` then immediate dereference → NPE → 500 | `AnimalSubjectServiceImpl.java:91-92`; `RefsServiceImpl.java:112-113`; `SubjectPathologyServiceImpl.java:109-110`; and siblings |
| B9 | **Medium** | `(boolean)` unboxing of a possibly-`null` RPC reply in subject-name check | `AnimalSubjectServiceImpl.java:150` |
| B10 | **Medium** | `LIKE` used for equality on user input → wildcard injection / validation bypass | `RefsRepositoryImpl.java:36,45,55,72,96` |
| B11 | **Medium** | JPQL injection (latent — the method has no production caller) | `AnimalSubjectRepositoryImpl.java:36` |
| B12 | **Medium** | DTO round-trip asymmetry loses/derives `pathology` differently | `AnimalSubjectDtoService.java:72` vs `:118` |
| B13 | **Medium** | Non-idempotent AMQP listeners, no DLQ, silent message loss | `RabbitMQPreclinicalService.java:59-104` |
| B14 | **Medium** | Bruker result zip silently written to `/tmp` root, never cleaned | `BrukerApiController.java:104` |
| B15 | **Medium** | Check-then-insert uniqueness with no DB constraint (TOCTOU) | `UniqueConstraintManagerImpl.java:53-64` |
| B16 | **Medium** | `NullPointerException` on `null` category/reftype in reference create/update | `RefsApiController.java:68,181` |
| B17 | **Low** | Reference delete with no in-use check → FK violation surfaced as 500 | `RefsApiController.java:84-98` |
| B18 | **Low** | Resource leak in `zipFolder` | `BrukerApiController.java:247-257` |
| B19 | **Low** | Trailing-slash-only route unreachable without the trailing slash | `SubjectPathologyApi.java:105` |
| B20 | **Low** | Inconsistent empty-collection responses between two copy-pasted methods | `ExtraDataApiController.java:380` vs `PathologyModelApiController.java:287` |

### 9.1 B1 — Unauthorized arbitrary file read + delete *(Critical)*

`shanoir-ng-import/src/main/java/org/shanoir/ng/importer/ImporterApi.java:132-133` declares:

```java
@PostMapping(value = "/import_dicom/", produces = {"application/json"}, consumes = {"application/json"})
ResponseEntity<ImportJob> importDicomZipFile(@RequestBody String dicomZipFilename)
```

It is the **only** endpoint in `ImporterApi` without `@PreAuthorize` — every sibling at lines 55, 66, 80, 92, 108, 119, 143, 164, 180, 192, 203, 217 has one. The implementation (`ImporterApiController.java:374-387`) does:

```java
File tempFile = new File(dicomZipFilename);
... new FileInputStream(tempFile.getAbsolutePath()) ...
} finally {
    tempFile.delete();          // unconditional, including on the IOException path
}
```

The comment at `:369` — *"We use this when coming from BRUKER upload"* — confirms this endpoint exists only to serve the preclinical flow, where the frontend echoes the server path back (`shanoir-ng-front/.../bruker-upload.component.ts:90`).

**Manifests as:** any authenticated user, with a single POST body containing a path, can (a) delete any file writable by the `import` container — which mounts `tmp:/tmp` (shared with preclinical, studies, datasets, nifti-conversion) and `logs:/var/log/shanoir-ng-logs` (`docker-compose.yml:214-217`) — and (b) read any readable file, with contents surfacing through the import job if it parses as a zip, and a distinguishable error otherwise (an oracle).

**Fix:** stop returning server paths to the client. Have `POST /bruker/upload` return an opaque, server-issued, per-user token; have `import_dicom` resolve that token server-side against a whitelisted base directory with `Path.normalize().startsWith(base)`; and add the same `@PreAuthorize` its siblings carry. As an immediate mitigation, add the `@PreAuthorize` and a containment check on `dicomZipFilename`.

### 9.2 B4 — Bruker RPC timeout and NPE *(High)*

`BrukerApiController.java:139`:
```java
boolean result = (boolean) rabbitTemplate.convertSendAndReceive(BRUKER_CONVERSION_QUEUE, request);
```
The preclinical `application.yml` configures only `spring.rabbitmq.host`/`port` (`:69-71`); it never sets `spring.rabbitmq.template.reply-timeout`, so `RabbitTemplate`'s built-in 5,000 ms default applies. Studies sets 60,000 ms (`shanoir-ng-studies/src/main/resources/application.yml:77`) and datasets raises it to 300,000 ms for downloads (`DatasetDownloaderServiceImpl.java:116`) — preclinical is the outlier.

**Manifests as:** for any Bruker dataset large enough to take >5 s to convert, the reply arrives after the template has given up; `convertSendAndReceive` returns `null`; `(boolean) null` throws `NullPointerException`; the catch-all at `:119` maps it to HTTP 422 **"Error while saving uploaded file"** — an error message unrelated to the actual failure. Meanwhile the conversion completes server-side and leaves orphaned output. This makes the feature unreliable-to-broken for real data while appearing to work for the tiny fixtures used in tests.

**Fix:** set `spring.rabbitmq.template.reply-timeout` explicitly (or `setReplyTimeout` at the call site) to exceed the worst-case conversion; use `Boolean result = (Boolean) …` and handle `null` as a distinct timeout error; better, make the conversion asynchronous with a task/progress event rather than a blocking HTTP request.

### 9.3 B6 — Distributed transaction gap *(High)*

`AnimalSubjectApiController.createAnimalSubject` (`:86-95`) runs, with **no `@Transactional` anywhere in the path**:

1. `createSubject(dto.getSubject())` → AMQP RPC to studies, which **commits a new `Subject` row in the studies database** (`AnimalSubjectServiceImpl.java:155`).
2. `validateAnimalSubjectCreation(...)` (`:89`) — **validation runs after the remote write**, and can throw.
3. `subjectService.save(animalSubject)` (`:91`) — can throw `ShanoirException`.

**Manifests as:** any failure at step 2 or 3 leaves a clinical `Subject` in the studies DB with **no matching `AnimalSubject`**. The user retries with the same name, `isSubjectNameAlreadyUsedInStudy` now returns `true`, and they are locked out of the name they just failed to create. There is no compensating delete.

**Fix:** move all validation before the remote call, and add an explicit compensating action (or a saga/outbox) around the remote create.

### 9.4 B7 — Upload failure reported as success *(High)*

`ExtraDataApiController.java:106-111`:
```java
ExaminationExtraData extradata = extraDataService.findById(id);   // may be null — unchecked
try {
    ExaminationExtraData uploadedData = saveUploadedFile(extradata, uploadfiles[0]);  // returns null on ANY error
    extraDataService.save(uploadedData);
    return new ResponseEntity<>(extradata, HttpStatus.OK);         // returns the ORIGINAL, not uploadedData
```
`saveUploadedFile` (`:357-374`) catches `Exception`, logs, `return null`. So on a storage failure the controller calls `save(null)` and then returns the stale entity with 200 OK. The copy-pasted twin at `PathologyModelApiController.java:211-215` has the *same* swallow but returns the reassigned variable — i.e. a `null` body with 200 OK. **Two variants of the same bug in two copies of the same method** — direct evidence of copy-paste drift.

**Fix:** null-check the entity (404), let `saveUploadedFile` propagate, return 5xx/422 on failure.

### 9.5 B8 — `orElse(null)` then dereference *(High)*

The pattern appears in every `update` method:
```java
final AnimalSubject subjectDB = subjectsRepository.findById(subject.getId()).orElse(null);
updateSubjectValues(subjectDB, subject);       // NPE if absent
```
(`AnimalSubjectServiceImpl.java:91-92`; identically at `RefsServiceImpl.java:112-113` and `SubjectPathologyServiceImpl.java:109-110`.) Some controllers pre-check existence, others do not, and there is a TOCTOU window regardless. Combined with §10.4, the NPE message reaches the client.

### 9.6 B12 — DTO round-trip asymmetry *(Medium)*

`AnimalSubjectDtoService.java:72` derives the pathology from the model, ignoring `dto.getPathology()`:
```java
subjectPathology.setPathology(dto.getPathologyModel() != null ? dto.getPathologyModel().getPathology() : null);
```
whereas the reverse mapping at `:118` sets it directly from the entity. **Manifests as:** GET a subject, PUT it back unchanged, and any `SubjectPathology` without a `pathologyModel` loses its pathology → `@NotNull` violation at flush (`SubjectPathology.java:63`) → 500. Also note `AnimalSubjectDtoService.java:44-47` builds a `SubjectDto` carrying only `id` and `preclinical: true` — name, study and all other clinical fields are silently absent from every `GET /subject/{id}` response.

### 9.7 B13 — AMQP listener robustness *(Medium)*

`RabbitMQPreclinicalService.createAnimalSubject` (`:88-104`) is **not idempotent**: on redelivery it constructs a second `AnimalSubject` with the same `targetId` and calls `save`, producing a duplicate-key error rather than a no-op. Both handlers catch `Exception` and rethrow `AmqpRejectAndDontRequeueException` (`:81,102`) — with no DLQ configured anywhere in `RabbitMQConfiguration`, **the message is discarded**. So a failed animal-subject deletion leaves an orphan row that nothing will ever clean up, and the only trace is a log line that logs `e.getMessage()` without the stack trace (`:80,101`).

`SubjectServiceImpl.deleteById` on the studies side (`:135`) sends the delete **after** committing its own delete, so the failure window is real.

### 9.8 B10 — `LIKE` misuse *(Medium)*

Every finder in `RefsRepositoryImpl` uses `LIKE` where `=` is meant (`:36,45,55,72,96`). Since the parameter is user-supplied, `%` and `_` are live wildcards. The security-relevant instance is `findByTypeAndValue`, called by `RefValueExistsValidator.java:70`: submitting a reference value of `%` matches any row of that type and **passes the "reference value exists" check**. On the read side, `GET /refs/category/%25` enumerates the whole catalogue. Beyond correctness, `LIKE` on an indexed column with a leading wildcard forces a full scan.

### 9.9 B11 — JPQL injection *(Medium, latent)*

`AnimalSubjectRepositoryImpl.java:36` concatenates a user-controlled string into JPQL:
```java
em.createQuery("SELECT a FROM AnimalSubject a LEFT JOIN a." + reference.getReftype() + " r WHERE r.value LIKE :value")
```
`reftype` is freely settable through `POST /refs` and `PUT /refs/{id}`. **Currently not reachable**: `findByReference` has no production caller (only `AnimalSubjectServiceTest.java:101` and `AnimalSubjectRepositoryTest.java:67`). Either delete the dead path or replace the concatenation with a whitelist of the five valid association names.

### 9.10 B15 — Uniqueness TOCTOU *(Medium)*

`UniqueConstraintManagerImpl.validate` (`shanoir-ng-ms-common/.../UniqueConstraintManagerImpl.java:53-64`) performs a `findBy` and rejects on a hit — a classic check-then-act with no database backstop, since the module declares **no** `unique = true` or `@UniqueConstraint`. Two concurrent `POST /therapy` with the same name both pass validation and both insert.

### 9.11 B16 — NPE on null reference fields *(Medium)*

`RefsApiController` calls `reference.getCategory().toLowerCase()` and `reference.getReftype().toLowerCase()` with no null guard, in both create (`:68-69`) and update (`:181-182`). A JSON body with `"reftype": null` yields a 500 instead of a 422.

### 9.12 B19 — Trailing-slash route *(Low)*

`SubjectPathologyApi.java:105` maps `"/subject/all/pathology/model/{pathoModelId}/"`. Spring Boot 3 disabled trailing-slash matching by default, so `…/model/5` returns 404 and only `…/model/5/` works. Every other route in the module omits the trailing slash.

---

## 10. Security & data-protection review

### 10.1 Access control — the central failure

| | studies | datasets | users | import | **preclinical** |
|---|---:|---:|---:|---:|---:|
| `@PreAuthorize` in `src/main` | 154 | 193 | 33 | 17 | **2** |

Both preclinical annotations are `hasRole('ADMIN')` on admin-only file-inventory endpoints (`ExtraDataApi.java:175`, `PathologyModelApi.java:130`). **No endpoint is guarded by study membership.** The security configuration stops at `.anyRequest().authenticated()` (`SecurityConfiguration.java:74-79`).

This is structural, not an oversight in a few annotations:

- The module **does not depend on `shanoir-ng-study-rights`** (`shanoir-ng-preclinical/pom.xml:33-44`); studies, datasets, users and import all do.
- It has no `StudyRightsService`, no `studySecurityService` bean, and does not consume `study-user-exchange` — so it has no local copy of the study-user rights table and *cannot* evaluate `hasRightOnStudy` even if the annotations were added.

**Consequences for a plain authenticated `ROLE_USER` with access to a single study:**
- Read, modify and delete the animal-subject record (species, strain, pathologies, therapies) of **any** subject in **any** study — `GET/PUT /subject/{id}`, `POST /subject/find`.
- Delete any subject's therapies or pathologies — `DELETE /subject/{id}/therapy/all`.
- Read and delete any examination's extra-data attachments and download any attachment file — `GET /examination/extradata/download/{id}`.
- Create, modify and **delete global reference values** shared by every study — `POST/PUT/DELETE /refs` — which can break data entry platform-wide or orphan existing rows (B17).
- Upload arbitrary archives to the shared `/tmp` volume — `POST /bruker/upload`.

Animal-subject records in OFSEP/Neurinfo contexts are research data with provenance value; unrestricted cross-study write access is a data-integrity issue even setting aside confidentiality.

### 10.2 Broken object-level authorization (IDOR)

Even within its own model the service does not check ownership. The consistent shape is "verify the parent exists, then act on the child by its own id":

- `SubjectTherapyApiController.java:110-124` — `deleteSubjectTherapy(id, tid)` confirms subject `id` exists, then `deleteById(tid)` with no check that therapy `tid` belongs to subject `id`.
- `SubjectTherapyApiController.java:148-163` — same for the getter.
- `SubjectPathologyApiController.java:106-112, 148-154` — same shape.
- `ExaminationAnestheticApiController.java:107-115` — **the `{id}` examination path variable is not read at all**; the handler goes straight to `findById(eaid)`.

### 10.3 Injection

- **Zip Slip** (B2) — the highest-impact injection, writing anywhere on the shared volume.
- **Path traversal** on `getOriginalFilename()` (`BrukerApiController.java:80,177`) — Spring does not sanitise this value.
- **Argument injection** into `dicomifier` via space-splitting (`ShanoirExec.java:345,347`). No shell is involved (`Runtime.exec(String[])` at `:282`), so this is argv manipulation rather than command injection — still enough to alter converter behaviour with a crafted filename.
- **JPQL injection** (B11) — latent, dead code path.
- **`LIKE` wildcard injection** (B10) — enables the reference-existence validation bypass.
- No SQL string concatenation with raw values was found; all named parameters are bound.

### 10.4 Information disclosure

`GlobalExceptionHandler.handleException` (`shared/controller/GlobalExceptionHandler.java:52-53`) returns `e.getMessage()` verbatim in a 500 body. Given the many unguarded NPE and `DataIntegrityViolationException` paths (§9.5, B15, B17), clients receive Hibernate/JDBC messages containing table names, column names and constraint names. Hardening: return a correlation id and log the detail server-side.

### 10.5 Secrets and configuration

Datasource credentials are hard-coded (`application.yml:34-35`), consistent with the rest of the platform (a deployment concern rather than a preclinical-specific one). No secrets were found in source or in the committed 4 MB log (checked for `password`, `Bearer`, `token`, `SELECT` — 0 hits each). CORS is correctly restricted to `front.server.url` (`SecurityConfiguration.java:96`). CSRF is disabled (`:72`), which is acceptable for a stateless bearer-token API.

One deployment note: `entrypoint` exports `SPRING_AMQP_DESERIALIZATION_TRUST_ALL=true` (`docker-compose/preclinical/entrypoint:18`). Preclinical's own listeners take `String` payloads, so it is not directly exploitable here, but it is a platform-wide setting worth revisiting.

---

## 11. Performance & scalability

1. **N+1 on the animal-subject list — the hot path.** `POST /subject/find` (`AnimalSubjectApiController.java:157-165`) loads N subjects, then maps each through `AnimalSubjectDtoService`, which walks two LAZY collections (`AnimalSubject.java:64,67`). Each `SubjectPathology` then eagerly loads four `@ManyToOne` associations (`animalSubject`, `pathology`, `pathologyModel`, `location` — `SubjectPathology.java:49-70`) and each `SubjectTherapy` its own. For N subjects with P pathologies and T therapies this is on the order of `1 + 2N + 4NP + kNT` queries. Fix: a projection query with `join fetch`, or an `@EntityGraph`.
2. **Lazy loading outside a transaction.** No controller or service in the subject path is `@Transactional`; this works only because `spring.jpa.open-in-view` defaults to `true`. Disabling OSIV — a routine performance change — would turn every `GET /subject/{id}` into a `LazyInitializationException`.
3. **Unbounded queries.** `GET /refs`, `GET /therapy`, `GET /pathology`, `GET /pathology/model`, `GET /anesthetic` and both `getAllFiles` endpoints call `findAll()` with no pagination. The reference table is the growth risk — it accumulates a row per distinct value across all studies.
4. **Filesystem stat per row.** `getAllFiles` calls `Paths.get(filepath).toFile().exists()` inside a stream over every record (`ExtraDataApiController.java:385`, `PathologyModelApiController.java:292`). On the S3 storage backend `filepath` is an object key, so `exists()` returns `false` for everything — the endpoint reports all files as missing.
5. **`deleteByAnimalSubject` issues one DELETE per row** in a loop (`SubjectPathologyServiceImpl.java:58-63`) instead of a bulk `delete … where animal_subject_id = ?`.
6. **Synchronous blocking upload.** `POST /bruker/upload` holds an HTTP request open across upload, unzip, remote conversion and re-zip. With `max-file-size: -1`, a handful of large concurrent uploads saturate the request pool and the shared volume.
7. **Test-suite cost.** Twelve `@SpringBootTest` classes boot the full context to run pure Mockito tests (§8.3).
8. **AMQP concurrency.** Preclinical's listeners use the default single-consumer factory while producers use `multipleConsumersFactory` (10–100 consumers). Bulk study copies will serialise behind `copy-animal-subject-queue`.

---

## 12. Technical debt inventory

| Rank | Item | Effort | Notes |
|---|---|---|---|
| 1 | No study-rights participation; 2 `@PreAuthorize` in 152 classes | **L** (2–3 wk) | needs the study-rights dependency, a `PreclinicalSecurityService`, per-endpoint annotations, and a security test suite |
| 2 | Bruker pipeline: Zip Slip, traversal, timeout/NPE, no cleanup, path-echo to `import` | **M** (1–2 wk) | includes redesigning the token handoff (B1) |
| 3 | 22 of 25 validator classes inert; validation semantics undefined | **M** (1 wk) | delete, then add DB constraints and real `@PreAuthorize` |
| 4 | 8-class-per-entity boilerplate (~8–9k LOC, 92 % identical siblings) | **L** (3–4 wk) | extract generic CRUD base classes into ms-common |
| 5 | Test suite: 13 dead IT classes, 212 template assertions, zero security/AMQP/DTO coverage | **L** (2–3 wk) | |
| 6 | Stringly-typed `Reference` model with reflective field-name→`reftype` coupling | **M** (1–2 wk) | typed catalogue or at minimum a complete `ReferenceEnum` + explicit `reftype` annotation attribute |
| 7 | `org.shanoir.ng.shared.*` shadowing ms-common; `RefValueExists*` misplaced in ms-common | **S** (1–2 d) | |
| 8 | Entities serialised directly as the HTTP contract (10 of 11 aggregates) | **M** (1–2 wk) | |
| 9 | No `@Transactional` on write services; OSIV-dependent lazy loading | **S** (1 d) | |
| 10 | Cross-DB shared PK with no integrity mechanism | **L** | architectural; document and add a reconciliation job |
| 11 | Dead code: `api/` package, `updateFromShanoirOld`, `findByReference`, 2 unused `RabbitTemplate` fields | **S** (0.5 d) | |
| 12 | 4 MB log committed since 2018; stale `.gitignore` entries | **S** (10 min) | |
| 13 | No DLQ / retry / idempotency on either inbound queue | **M** (3–5 d) | platform-wide |
| 14 | `allow-circular-references: true` in all profiles | **S** (0.5 d) | |
| 15 | Duplicated `CopyRequest` wire contract | **S** (1 h) | move to ms-common |

### Dependency observations

`joda-time 2.10.10` (`pom.xml:57-61`) alongside `jackson-datatype-joda` on a Java 21 / Spring Boot 3.4 stack — Joda-Time has been superseded by `java.time` since Java 8. `commons-collections 3.2.2` (`:63-68`) is the pre-generics 3.x line, historically associated with deserialization gadget chains; migrate to `commons-collections4` or drop it. The `pom.xml` comment `<!-- SpringFox Swagger UI -->` (`:44`) is stale — the project moved to springdoc. `docker-compose.yml:289` still pins `preclinical:NG_v2.12.0` while the POM is at 3.4.0. `shanoir-ng-back/pom.xml:262-270` declares a `spring-snapshots` repository over plain **HTTP**.

---

## 13. Improvement roadmap

### Quick wins (< 1 day each)

1. Add `@PreAuthorize` to `ImporterApi.java:132` matching its siblings, and reject any `dicomZipFilename` that does not normalise inside a whitelisted base directory. **Do this first** — it is a two-line change that closes B1's worst half.
2. Add Zip Slip containment in `unzipBrukerArchive` (`BrukerApiController.java:190-208`): resolve each entry against the target and assert `normalize().startsWith(targetRoot)`.
3. Sanitise `getOriginalFilename()` with `StringUtils.cleanPath` + a basename check at `:80` and `:177`.
4. Set `spring.rabbitmq.template.reply-timeout` and change `(boolean)` → `Boolean` with an explicit null branch at `BrukerApiController.java:139` and `AnimalSubjectServiceImpl.java:150`.
5. Set finite `spring.servlet.multipart.max-file-size` / `max-request-size` (`application.yml:77-78`).
6. Fix `File.createTempFile(destinationFilePath, …)` (`:104`) to `File.createTempFile("result", suffix, new File(brukerDir))`.
7. Delete `shanoir-ng-preclinical.log` from git; remove the stale `null*`, `nullbruker/` and `3_init_preclinical.sql` `.gitignore` entries.
8. Fix `BrukerApiControllerTest` to use `@DynamicPropertySource`/`@TestPropertySource` so tests stop writing to the real `/tmp`.
9. Delete the `api/` package, `updateFromShanoirOld`, `findByReference` (and its interface/impl), and the two unused `RabbitTemplate` fields.
10. Change `LIKE` → `=` throughout `RefsRepositoryImpl`.
11. Stop returning `e.getMessage()` from `GlobalExceptionHandler`'s catch-all.
12. Add `@Transactional` to the write methods of every `*ServiceImpl`.

### Medium (1–2 weeks each)

13. **Wire study rights.** Add `shanoir-ng-study-rights`, consume `study-user-exchange`, implement `PreclinicalSecurityService` with `hasRightOnAnimalSubject(id, right)`, and annotate every endpoint. Model it on `shanoir-ng-datasets/.../DatasetSecurityService.java`.
14. **Fix object-level authorization** — every nested-resource handler must verify parent ownership; add `findByIdAndAnimalSubjectId`-style repository methods.
15. **Security test suite** mirroring `DatasetApiSecurityTest`, run with filters *enabled*.
16. **Delete the 22 inert validators** and add real DB unique constraints via a migration; map violations to 409.
17. **Fix the Bruker handoff** — replace the server-path echo with an opaque per-user token resolved server-side.
18. **Harden the AMQP listeners** — make `createAnimalSubject` idempotent, declare a DLQ, log stack traces.
19. **Fix the N+1** on `/subject/find` and `/subject/{id}` with `@EntityGraph`/`join fetch`; add pagination to the `findAll` endpoints.
20. **Test the untested** — `RabbitMQPreclinicalService`, `AnimalSubjectDtoService`, `BrukerApiController` failure modes.
21. **Convert the 13 IT classes to Testcontainers or delete them**, and add `maven-failsafe-plugin` if they are kept.

### Large (refactors)

22. **Extract generic CRUD base classes** into ms-common (`AbstractCrudApi<T>`, `AbstractCrudServiceImpl<T, R>`) and collapse the 11 entity templates onto them: ~4,000 LOC of main and ~2,000 of test code removed, and each future fix applied once instead of eleven times.
23. **Remove the ms-common shadowing** — delete this module's `org.shanoir.ng.shared.*` duplicates and relocate `RefValueExists*` into `org.shanoir.ng.preclinical.references`.
24. **Rework the reference catalogue** — either typed sub-entities per category, or keep the single table but make `reftype` an explicit annotation attribute (`@RefValueExists(reftype = "specie")`) so it stops depending on Java field names.
25. **Introduce a DTO/MapStruct layer** for all aggregates so entities stop being the wire format.
26. **Formalise the shared PK contract** with studies: a documented invariant plus a reconciliation job that reports `animal_subject` rows with no matching `subject` (the orphans B13 produces today).

**Recommendation on merging:** do **not** merge into studies/datasets (§5.4). Item 22 plus item 13 delivers most of the benefit of a merge at a fraction of the risk.

---

## 14. Future work & feature directions

1. **Make the Bruker import a first-class asynchronous job.** Today it is a blocking HTTP request that returns a filesystem path. Reworking it into a task with progress events (the `events-exchange` infrastructure already exists and is already used by this service) would remove the timeout class of bugs, the path-echo vulnerability, and the request-pool exhaustion in one change — and would align preclinical with how the clinical import already reports progress.
2. **Unify the animal and clinical import funnels behind one job model.** `import` already handles DICOM, NIfTI, BIDS and EEG; Bruker is the odd one out with a bespoke entry point in a different service. Routing Bruker through the same `ImportJob` machinery (with preclinical contributing only the Bruker→DICOM step) would let animal imports inherit study-card application, PACS routing and Solr indexing for free.
3. **Promote preclinical metadata into Solr search.** Species, strain, pathology and therapy are exactly the facets preclinical researchers filter on, and none of them are indexed today. This needs the events already published on `events-exchange` to be consumed by the datasets Solr indexer.
4. Secondary directions: BIDS-animal export alignment; ontology-backed reference values using the existing `ontoneurolog-preclinic.owl`; multi-tenant reference catalogues (per-study overrides of the global list) — the last of which becomes tractable only once study rights exist.

---

## 15. Appendix

### 15.1 Largest main files

| LOC | File |
|---:|---|
| 393 | `preclinical/extra_data/ExtraDataApiController.java` |
| 299 | `preclinical/pathologies/pathology_models/PathologyModelApiController.java` |
| 299 | `preclinical/contrast_agent/ContrastAgent.java` |
| 293 | `preclinical/bruker/BrukerApiController.java` |
| 280 | `preclinical/anesthetics/examination_anesthetics/ExaminationAnesthetic.java` |
| 252 | `preclinical/pathologies/subject_pathologies/SubjectPathologyApiController.java` |
| 248 | `preclinical/therapies/subject_therapies/SubjectTherapy.java` |
| 238 | `preclinical/subjects/model/AnimalSubject.java` |
| 238 | `preclinical/pathologies/subject_pathologies/SubjectPathology.java` |
| 234 | `preclinical/therapies/subject_therapies/SubjectTherapyApiController.java` |

### 15.2 Complexity hotspots

| File:lines | Why |
|---|---|
| `BrukerApiController.java:71-124` | 3 nested catch blocks, 6 sequential I/O side effects, no cleanup, mixed responsibilities (HTTP, filesystem, zip, AMQP) |
| `ExtraDataApiController.java:92-391` | 3 entity types × 3 validators × 3 services in one class; 14 handlers |
| `AnimalSubjectApiController.java:83-143` | distributed transaction + 4 validators, no `@Transactional` |
| `AnimalSubjectServiceImpl.java:102-134` | in-place graph merge over two child collections via `Utils.syncList` |
| `RefValueExistsValidator.java:59-95` | reflection over fields, string-built getter names, 3 swallowed exception types |
| `FieldEditionSecurityManagerImpl.validate` (ms-common) | reflective, and NPEs if `originalEntity` is null when any annotated field exists |

### 15.3 TODO / FIXME / XXX / HACK inventory

**Zero occurrences** of `TODO`, `FIXME`, `XXX` or `HACK` in `src/main` or `src/test`. Dead and deferred work is instead recorded as commented-out code:

| Location | Content |
|---|---|
| `PathologyServiceImpl.java:106-124` | `updateFromShanoirOld` — `return true;` plus ~15 commented lines targeting a removed `RabbitMqConfiguration` |
| `SubjectTherapy.java:63` | `// @RefValueExists` — disabled validation |
| `ExaminationAnesthetic.java:50` | `//@RefValueExists` — disabled validation |
| `ContrastAgent.java:47,55,61` | `//@RefValueExists` ×3 — disabled validation |
| `SubjectPathology.java:58` | `// @NotNull` on `pathologyModel` — disabled constraint |
| `PathologyModel.java` | 2 commented annotation lines |
| `ExaminationExtraData.java` | 2 commented annotation lines |
| `BrukerApiController.java` | 3 commented lines |
| `TherapyServiceTest.java:128-136` | commented-out test still referencing `pathologiesService` |
| `PathologyServiceTest.java:107-125` | two commented-out tests |
| `ShanoirExec.java:349` (nifti-conversion) | commented-out `LOG.error` |

### 15.4 Verification notes

Two claims in this report were checked empirically rather than inferred, because both could plausibly have gone the other way:

- **`File.createTempFile` with an absolute-path prefix** (§6.3 F6). A standalone JDK 25 program showed it does **not** throw; the JDK reduces the prefix to its final path segment and creates the file in `java.io.tmpdir`. An earlier reading of the JDK's `generateFile` name check suggested an `IOException`; that would have been wrong, and the actual behaviour (silent relocation) is the more insidious bug. Note that the frontend's parsing at `bruker-upload.component.ts:89` (`res.substring(res.indexOf(".") + 1, …)`) currently works *because of* this truncation — it is accidentally load-bearing.
- **`@Mock`/`@InjectMocks` under `@SpringBootTest` without `@ExtendWith(MockitoExtension.class)`** (§8.3). The module has zero `@ExtendWith`, zero `MockitoAnnotations.openMocks`, and no `junit-platform.properties`, which suggested the service tests could not run at all. They can: Spring's `MockitoTestExecutionListener` is registered by default and initialises standard Mockito annotations — visible in the listener chain recorded in the committed 2018 log. The tests execute; the criticism is their content and their cost, not their viability.
