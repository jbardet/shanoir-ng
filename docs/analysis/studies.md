# `shanoir-ng-studies` — Engineering Audit

**Scope:** `/home/jamesbardet/Documents/code/shanoir-ng/shanoir-ng-studies` at commit `867e53290` (develop line), Shanoir-NG 3.4.0.
**Method:** static read of all `src/main` and `src/test` sources plus cross-service greps into `shanoir-ng-ms-common`, `shanoir-ng-study-rights`, `shanoir-ng-datasets`, `shanoir-ng-import`, `shanoir-ng-users`, `docker-compose/`. No build was run. Every claim below carries a `file:line` citation; where I am inferring rather than observing, I say so explicitly.

---

## 1. Executive summary

`shanoir-ng-studies` is the organisational and access-control core of the Shanoir-NG platform. It owns the `studies` MariaDB schema and is the **authoritative source of authorization data** for the whole platform: it stores `study_user` rows (user ↔ study ↔ rights ↔ centers) and broadcasts every mutation over the `study-user-exchange` fanout so that `datasets`, `import` and `users` can maintain local read replicas of the rights table. It also owns centers, acquisition equipments, manufacturers/models, coils, subjects, subject-study links, tags, timepoints, profiles, data-user agreements (DUA), DUA drafts, and study statistics.

### Overall health verdict: **poor / at risk**

The service works for the happy path but the authorization layer — the single most safety-critical part of this codebase — contains at least three defects that permit cross-study data access, one of which (§8.1) exposes **every subject in the platform to every authenticated user**. The rights-broadcast mechanism is a best-effort, non-transactional dual write with swallowed failures and no dead-letter queue. Test coverage is heavily skewed towards the trivial reference-data packages (centers, coils, manufacturers) while the DUA, rights-broadcast, RabbitMQ and copy-datasets code paths have **zero** tests.

One correction to the audit brief up front: **there is no study-card rules engine in this service.** The only study-card artefact here is the `StudyCardPolicy` enum (`src/main/java/org/shanoir/ng/study/model/StudyCardPolicy.java`), a per-study `MANDATORY`/`DISABLED` flag. All study-card condition evaluation, DICOM tag matching and application to acquisitions lives in `shanoir-ng-datasets` (87 study-card references there vs. 8 trivial ones here). Likewise `study-user-exchange` is declared as a **fanout**, not a topic exchange (`shanoir-ng-ms-common/.../RabbitMQConfiguration.java:394`).

### Top findings, ranked

1. **CRITICAL — five `@PostFilter`/`@PostAuthorize` "filter" helpers are no-ops.** They build a filtered list into a local variable and then assign it back to the *parameter* (`dtos = newList;`), which discards it. `GET /subjects` is guarded only by `filterSubjectDTOsHasRightInOneStudy`, so it returns **every subject in the database** — name, identifier, hemispheric dominance — to any authenticated `USER`. `StudySecurityService.java:420, 446, 472, 499, 522`; wired at `SubjectApi.java:71`.
2. **CRITICAL — `/dua/**` is `permitAll()` and two of its three endpoints have no method-level guard.** `PUT /dua/{duaId}` and `GET /dua/{duaId}` are reachable with **no authentication at all**. `SecurityConfiguration.java:76` + `DuaDraftAPI.java:58-63, 71-73`.
3. **CRITICAL — subject-creation authorization bypass via `subjectStudyList`.** The `@PreAuthorize` checks `subject.getStudy()` and returns early (`StudySecurityService.java:350-352`), but the service then *overwrites* the study from `subjectStudyList[0]` (`SubjectServiceImpl.java:293-298` → `:334`). A caller can pass a study they may import into for the check and a victim study for the write.
4. **HIGH — `hasRightOnSubjects` is "any-of" where it must be "all-of", and fails open on an empty result.** It flattens the `StudyUser` rows of *all* target studies into one list and asks whether *any* of them grants the right (`StudySecurityService.java:283-295`). This is the guard behind `POST /studies/copyDatasets`.
5. **HIGH — the rights broadcast is an unguarded dual write with swallowed failures.** `broadcast()` is called inside `@Transactional` methods before commit and its `MicroServiceCommunicationException` is caught and logged at ERROR (`StudyServiceImpl.java:165-169, 265-269, 744-748`; `StudyUserServiceImpl.java:120-121`). A rollback after publish grants rights that do not exist; a publish failure after commit leaves other services permanently stale. There is **no DLQ, no retry, no outbox, no reconciliation job**.
6. **HIGH — `SubjectStudy` update is a confused deputy.** The `@PreAuthorize` evaluates rights on the study **supplied in the request body** (`SubjectStudyApi.java:53-56`) while the service loads and mutates the subject-study by id from the DB without re-checking (`SubjectStudyServiceImpl.java:52-58`).
7. **HIGH — `findStudyUsersByStudyId` assigns the union of *all* the study's centers to *every* `StudyUser`.** `StudyUserServiceImpl.java:101` calls a study-scoped query (`StudyUserRepository.java:43-44`) inside a per-user loop. Center-scoped rights returned by `GET /studies/studyUser/{studyId}` are therefore wrong, and if the front-end round-trips that payload into a `PUT`, the widened center scope is persisted.
8. **MEDIUM — three membership/metadata endpoints have no study-level guard.** `GET /studies/studyUser/{studyId}` (`StudyApi.java:409`), `GET /studies/dua-download/{studyId}/{fileName}` (`StudyApi.java:359`) and `POST /common` (`CommonApi.java:37`) are open to any authenticated user and leak study membership, DUA documents, and arbitrary subject/study/center names by id.

---

## 2. Purpose & domain responsibilities

The service is the platform's *registry* and *authorization authority*. Concretely it owns:

| Domain | Entities | Notes |
|---|---|---|
| Study | `Study`, `StudyExtraDetails`, `StudyStatus`, `StudyType`, `StudyCardPolicy`, `InclusionRateUnit` | root aggregate; draft/approval workflow |
| Rights | `StudyUser` (+ `study_user_study_user_rights`, `study_user_center`) | authoritative; broadcast platform-wide |
| Membership scoping | `StudyCenter` | study ↔ center with `subjectNamePrefix` |
| Subjects | `Subject`, `SubjectStudy`, `SubjectStudyTag`, `PseudonymusHashValues`, `UserPersonalCommentSubject` | PHI: `birthDate`, `identifier`, pseudonymus hashes |
| Reference data | `Center`, `AcquisitionEquipment`, `Manufacturer`, `ManufacturerModel`, `Coil` | shared with import/datasets |
| Classification | `Tag`, `StudyTag`, `Timepoint`, `Profile` | |
| Governance | `DataUserAgreement`, `DuaDraft` | signature workflow + external draft link |
| Cross-cutting | `StudyExamination`, `KeyValue` | denormalised study↔examination index |

Responsibilities it does **not** own, despite the brief: study-card rules (in `datasets`), quality-control computation (it only *receives* computed tags on `STUDIES_SUBJECT_STUDY_STUDY_CARD_TAG`), and study invitations (`STUDY_INVITATION_QUEUE` is declared in `ms-common` but has no producer or consumer in this module).

---

## 3. Architecture & code structure

### 3.1 Package tree (main sources, 28,101 LOC total incl. tests)

```
org.shanoir.ng
├── study                    7,407 LOC / 38 files   ← core: model, dto, repository, security, service, controler, dua
├── subject                  2,928 LOC / 19 files
├── manufacturermodel        1,597 LOC / 19 files
├── center                   1,410 LOC / 10 files
├── acquisitionequipment     1,193 LOC / 11 files
├── subjectstudy             1,106 LOC / 13 files
├── coil                       940 LOC /  9 files
├── configuration              742 LOC /  5 files   ← amqp listeners + Spring Security
├── tag                        678 LOC / 12 files
├── shared                     658 LOC / 11 files   ← local HATEOAS, CommonApi, exceptions
├── dua                        657 LOC / 10 files   ← DuaDraft (distinct from study.dua!)
├── profile                    332 LOC /  6 files
├── studycenter                329 LOC /  5 files
├── timepoint                  295 LOC /  3 files
├── bids                       294 LOC /  4 files
├── studyexamination           278 LOC /  4 files
├── key                        199 LOC /  5 files
├── challenge                   96 LOC /  2 files
└── messaging                   51 LOC /  1 file    ← StudyUserUpdateBroadcastService
```

### 3.2 Layering

The conventional layering is `*Api` (interface: HTTP mapping + `@PreAuthorize`) → `*ApiController` (`@Controller` implementing it) → `*Service` (interface: a **second** `@PreAuthorize` layer) → `*ServiceImpl` → `*Repository`. MapStruct mappers (`*Mapper` + hand-written `*Decorator`) convert entities to DTOs.

Two structural problems follow from this:

- **Authorization is expressed in two places with different rules.** `PUT /studies/{studyId}` is guarded at the API by `idMatches + hasRightOnStudy(CAN_ADMINISTRATE)` (`StudyApi.java:220`) and at the service by `hasRightOnStudy(CAN_ADMINISTRATE) + studyUsersMatchStudy` (`StudyService.java:116`). Any reader has to check both, and there is no test asserting the two stay consistent.
- **Two unrelated packages are both called "dua".** `org.shanoir.ng.study.dua` holds `DataUserAgreement` (the signature record, served under `/studies/dua`), while `org.shanoir.ng.dua` holds `DuaDraft` (the external draft, served under `/dua`). This near-collision is what makes the `permitAll("/dua/**")` rule in `SecurityConfiguration.java:76` so easy to misread as safe — see §8.2.

### 3.3 JPA entity model

`Study` (`study/model/Study.java`) is the aggregate root. Its `@NamedEntityGraph("Study.All")` (`Study.java:75-81`) eagerly fetch-joins **eleven** attributes, six of which are `List` bags: `studyUserList`, `studyCenterList`, `subjectStudyList`, `studyTags`, `timepoints`, `tags`, plus the `@ElementCollection`s `protocolFilePaths` and `dataUserAgreementPaths`, plus the `examinations` set. This graph is applied to the plain `findById` (`StudyRepository.java:31-32`), so *every* single-study lookup issues one query with a large cartesian product. The team has already hit the consequences — see the "two bags constraint" workaround comment at `StudyUserServiceImpl.java:100`.

Other entity-level observations:

- `AbstractEntity` (in `ms-common`) declares no `equals`/`hashCode`; only `PseudonymusHashValues` and `SubjectStudyTagPrimaryKey` implement them. Entities therefore use identity semantics inside `HashSet`s — see the non-idempotency bug in §8.13.
- `Study` uses `@GenericGenerator(name = "IdOrGenerate", strategy = "increment")` (`Study.java:83`), Hibernate's in-JVM `increment` generator. It is not safe across replicas; if `studies` is ever scaled beyond one instance this produces duplicate-key failures. (`StudyUser` uses the custom `UseIdOrGenerate` instead — `StudyUser.java:49`.)
- `StudyUser.getStudyId()` (`StudyUser.java:142-144`) dereferences `study` with no null guard and is `@Transient`+`@JsonInclude`, so it is invoked during every serialization.
- `Subject` has a proper unique index on `(name, study_id)` (`Subject.java:59`), and `StudyUser` on `(study_id, userId)` (`StudyUser.java:48`). These DB constraints are the only thing preventing several of the races described in §8.

### 3.4 Owned DB schema

Tables owned (inferred from `@Table`/`@CollectionTable`/`@JoinTable`): `study`, `study_extra_details`, `study_user`, `study_user_study_user_rights`, `study_user_center`, `study_center`, `study_examination`, `subject`, `subject_study`, `subject_study_tag`, `pseudonymus_hash_values`, `user_personal_comment_subject`, `tag`, `study_tag`, `timepoint`, `center`, `acquisition_equipment`, `manufacturer`, `manufacturer_model`, `coil`, `profile`, `data_user_agreement`, `dua_draft`, `key_value`, `protocol_file_path`, `data_user_agreement_file`. Plus one stored procedure, `getStudyStatistics`, invoked from `StudyRepositoryImpl.java:42`.

---

## 4. External interfaces

### 4.1 REST API

Base paths are relative to `/shanoir-ng/studies/` (nginx strips the prefix — `docker-compose/nginx/shanoir.template.conf:28`, proxying to `:9902`).

| Method | Path | Authorization | Purpose |
|---|---|---|---|
| GET | `/studies` | `ADMIN,EXPERT,USER` + service `@PostFilter hasRightOnTrustedStudy(CAN_SEE_ALL)` | list studies |
| GET | `/studies/light` | `ADMIN,EXPERT,USER` | list studies (light DTO) |
| GET | `/studies/draft` | `ADMIN,EXPERT,USER` **(API)**; `ADMIN` **(service)** | list draft studies |
| GET | `/studies/public/data` | **anonymous** (`SecurityConfiguration.java:76`) | public study catalogue |
| GET | `/studies/public/connected` | authenticated, no role check | public studies the user is *not* in |
| GET | `/studies/names` | `ADMIN,EXPERT,USER` + broken `@PostFilter` (§8.1) | id/name list |
| GET | `/studies/namesAndCenters` | `ADMIN,EXPERT,USER` | id/name/centers |
| GET | `/studies/{studyId}` | `ADMIN,EXPERT,USER` + `@PostAuthorize hasRightOnTrustedStudyDTO(CAN_SEE_ALL)` | study detail |
| POST | `/studies` | `ADMIN,EXPERT` (+ service `studyUsersStudyNull`) | create study |
| PUT | `/studies/{studyId}` | `ADMIN,EXPERT` + `idMatches` + `CAN_ADMINISTRATE` (+ service `studyUsersMatchStudy`) | update study |
| DELETE | `/studies/{studyId}` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | delete study |
| PUT | `/studies/approveDraftStudy/{studyId}` | `ADMIN` | approve a draft study |
| POST | `/studies/copyDatasets` | `ADMIN` or `hasRightOnCopy(#copyData)` **(broken, §8.4)** | copy datasets to a study |
| GET | `/studies/detailedStorageVolume/{studyId}` | `ADMIN` or `CAN_SEE_ALL` | storage volume |
| POST | `/studies/detailedStorageVolume` | `ADMIN` or `filterVolumesHasRightOnStudies` | bulk storage volume |
| GET | `/studies/rights/{studyId}` | `ADMIN,EXPERT,USER` (self-scoped in service) | my rights on a study |
| GET | `/studies/rights/all` | `ADMIN,EXPERT,USER` (self-scoped) | all my rights |
| GET | `/studies/hasOneStudy` | `ADMIN,EXPERT,USER` | do I have CAN_IMPORT anywhere |
| GET | `/studies/tags/{studyId}` | `ADMIN` or any of `CAN_SEE_ALL,CAN_IMPORT,CAN_ADMINISTRATE` | study tags |
| POST | `/studies/protocol-file-upload/{studyId}` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | upload protocol |
| GET | `/studies/protocol-file-download/{studyId}/{fileName}/` | `ADMIN` or `CAN_DOWNLOAD` | download protocol |
| POST | `/studies/dua-upload/{studyId}` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | upload DUA pdf |
| GET | `/studies/dua-download/{studyId}/{fileName}/` | **`ADMIN,EXPERT,USER` only — no study right (§8.9)** | download DUA pdf |
| GET | `/studies/dua` | `ADMIN,EXPERT,USER` (self-scoped) | my pending DUAs |
| PUT | `/studies/dua/{duaId}` | `ADMIN,EXPERT,USER` + `checkUserOnDUA` | accept a DUA |
| GET | `/studies/dua/study/{studyId}` | `ADMIN,EXPERT,USER` | do I have a pending DUA here |
| GET | `/studies/studyUser/{studyId}` | **`ADMIN,EXPERT,USER` — no study right (§8.8)** | list study members |
| POST | `/studies/studyUser/{studyId}` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | add member |
| DELETE | `/studies/studyUser/{studyId}/{userId}` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | remove member |
| GET | `/studies/studyUser/right/{right}` | `ADMIN,EXPERT,USER` | my studies with a given right |
| GET | `/studies/statistics/{studyId}` | `ADMIN,EXPERT` — **no per-study check** | study statistics |
| GET | `/studies/files` | `ADMIN` | all protocol/DUA file entries |
| DELETE | `/subjects/{subjectId}` | `ADMIN` or `EXPERT` + `hasRightOnSubjectForEveryStudy(CAN_ADMINISTRATE)` | delete subject |
| GET | `/subjects` | `ADMIN,EXPERT,USER` + **broken** `@PostAuthorize` (§8.1) | **all subjects** |
| GET | `/subjects/filter` | `ADMIN,EXPERT,USER` (scoped via `studyService.findAll()`) | paged clinical subjects |
| GET | `/subjects/names` | `ADMIN,EXPERT,USER` (scoped in service) | subject id/name |
| POST | `/subjects/names` | `ADMIN,EXPERT,USER` (scoped in service) | subject id/name by ids |
| GET | `/subjects/{subjectId}` | `ADMIN,EXPERT,USER` + `@PostAuthorize hasRightOnSubject(CAN_SEE_ALL)` | subject detail |
| POST | `/subjects` | `ADMIN` or `hasRightOnTrustedSubjectForOneStudy(CAN_IMPORT)` **(bypassable, §8.3)** | create subject |
| PUT | `/subjects/{subjectId}` | `ADMIN` or `hasRightOnSubjectForOneStudy(CAN_IMPORT)` | update subject |
| GET | `/subjects/{studyId}/allSubjects` | `ADMIN` or `CAN_SEE_ALL` | subjects of a study |
| GET | `/subjects/findByIdentifier/{id}` | `ADMIN,EXPERT,USER` + `@PostAuthorize` | lookup by identifier |
| GET | `/subjects/nameExists/{name}/inStudy/{studyId}` | `ADMIN` or `hasAnyRightOnStudy(#studyId)` | name-collision probe |
| PUT | `/subjectStudy/{subjectStudyId}` | `ADMIN` or body-study `CAN_IMPORT`/`CAN_ADMINISTRATE` **(confused deputy, §8.5)** | update subject-study |
| POST | `/dua` | `ADMIN,EXPERT` + `CAN_ADMINISTRATE` | create DUA draft, email link |
| PUT | `/dua/{duaId}` | **NONE — unauthenticated (§8.2)** | overwrite DUA draft |
| GET | `/dua/{duaId}` | **NONE — unauthenticated (§8.2)** | read DUA draft |
| POST | `/common` | authenticated, **no authorization (§8.11)** | resolve study/center/subject/equipment names by id |
| GET | `/challenges` | authenticated, no role check | challenge studies |
| GET | `/keys/{key}` | `ADMIN,EXPERT,USER` | key-value lookup |
| GET | `/profiles/all` | `ADMIN,EXPERT` | anonymisation profiles |
| GET | `/bids/neurobagel/studyId/{studyId}` | authenticated, **no authorization** | neurobagel BIDS export |
| — | `/centers`, `/coils`, `/manufacturers`, `/manufacturermodels`, `/acquisitionequipments` | role-only (`ADMIN`/`EXPERT` to write, `+USER` to read) | reference data CRUD |

### 4.2 RabbitMQ

**Consumed (this service is the listener).** All use `containerFactory = "singleConsumerFactory"` unless noted.

| Queue / binding | Payload | Handler |
|---|---|---|
| `examination-study-queue` ← `events-exchange` key `CREATE_EXAMINATION_EVENT` | `ShanoirEvent` JSON | `RabbitMQStudiesService.java:127` |
| `examination-studies-queue` ← `events-exchange` key `CREATE_EXAMINATIONS_EVENT` | `ShanoirEvent`+`StudyExaminationsDTO` | `RabbitMQStudiesService.java:174` |
| `examination-study-delete-queue` | `ShanoirEvent` JSON | `RabbitMQStudiesService.java:193` |
| `study-name-queue` (RPC) | `long` studyId → `String` | `RabbitMQStudiesService.java:209` |
| `study-anonymisation-profile-queue` (RPC) | `long` studyId → `String` | `RabbitMQStudiesService.java:220` |
| `study-subscription-queue` (RPC) | `ShanoirEvent` JSON → `boolean` | `RabbitMQStudiesService.java:235` |
| `studies-subject-study-study-card-tag` | `List<SubjectQualityTagDTO>` | `RabbitMQStudiesService.java:278` |
| `center-create-queue` (RPC) | `CreateCenterForStudyMessage` → `"centerId:studyCenterId"` | `RabbitMQStudiesService.java:303` |
| `acquisition-equipment-create-queue` (RPC) | `CreateEquipmentForCenterMessage` → `Long` | `RabbitMQStudiesService.java:336` |
| `study-participants-tsv` (RPC) | `Long` studyId → TSV `String` | `RabbitMQStudiesService.java:365` |
| `study-draft-state-queue` (RPC) | `String` studyId → `"true"/"false"/"NOT_FOUND"/"ERROR"` | `RabbitMQStudiesService.java:387` |
| `delete-user-queue` | `ShanoirEvent` JSON | `StudyUserServiceImpl.java:109` |
| `dataset-subject-queue` (RPC, multi-consumer) | `String` studyId → `List<SimpleSubjectDTO>` JSON | `RabbitMQSubjectService.java:70` |
| `dataset-subject-study-queue` (RPC, multi) | `IdName` JSON → study name | `RabbitMQSubjectService.java:87` |
| `subjects-name-queue` (RPC, multi) | `IdName` JSON → `boolean` | `RabbitMQSubjectService.java:124` |
| `subjects-queue-with-datasets` (RPC, multi) | `Subject` JSON → `Long` | `RabbitMQSubjectService.java:137` |
| `subjects-queue-without-datasets` (RPC, multi) | `Subject` JSON → `Long` | `RabbitMQSubjectService.java:151` |
| `center-update-queue`, `center-delete-queue` | see `RabbitMqCenterService` | `acquisitionequipment/service/RabbitMqCenterService.java` |
| `acquisition-equipment-center-queue`, `acquisition-equipment-code-queue`, `acquisition-equipment-update-queue`, `equipment-from-code-queue` | equipment lookups | `acquisitionequipment/service/*` |

**Published (this service is the producer).**

| Destination | Kind | Payload | Producer |
|---|---|---|---|
| **`study-user-exchange`** (FanoutExchange, routing key `study-user` — *ignored by fanout*) | broadcast | `List<StudyUserCommand>` JSON | `StudyUserUpdateBroadcastService.java:44` |
| `study-name-update-queue` (`STUDY_UPDATE_QUEUE`) | **RPC** | `StudyDTO` JSON → error `String` | `StudyServiceImpl.java:895` |
| `study-user-mail-queue` | fire-and-forget | `EmailStudyUsersAdded` JSON | `StudyServiceImpl.java:785` |
| `draft-study-mail-queue` | fire-and-forget | `EmailStudy` JSON | `StudyServiceImpl.java:798` |
| `approve-study-mail-queue` | fire-and-forget | `EmailStudy` JSON | `StudyServiceImpl.java:815` |
| `dua-draft-mail-queue` | fire-and-forget | `DuaDraftWrapper` JSON | `DuaDraftAPIController.java:121` |
| `study-datasets-detailed-storage-volume` | **RPC** | `Long` → `StudyStorageVolumeDTO` JSON | `StudyServiceImpl.java:970` |
| `study-datasets-total-storage-volume` | **RPC** | `List<Long>` → `Map<Long,DTO>` JSON | `StudyServiceImpl.java:992` |
| `subject-update-queue` | **RPC** (reply discarded) | `SubjectDTO` JSON | `SubjectServiceImpl.java:445` |
| `subject-batch-update-queue` | **RPC** (reply discarded) | `SubjectBatchDTO` JSON | `SubjectServiceImpl.java:463` |
| `delete-subject-queue` | fire-and-forget | `ShanoirEvent` JSON | `SubjectServiceImpl.java:139` |
| `delete-animal-subject-queue` | fire-and-forget | `String` subjectId | `SubjectServiceImpl.java:135` |
| `copy-animal-subject-queue` | fire-and-forget | `{sourceId,targetId}` JSON | `RelatedDatasetServiceImpl.java:219` |
| `copy-datasets-to-study-queue` | fire-and-forget | `RelatedDataset` JSON | `RelatedDatasetServiceImpl.java:271` |
| `events-exchange` (topic) | via `ShanoirEventService` (ms-common) | `ShanoirEvent` | many, e.g. `StudyApiController.java:137` |

Fanout consumers of `study-user-exchange`: `study-user-queue-dataset` (`RabbitMQDatasetsService.java:153`), `study-user-queue-import` (`RabbitMQImportService.java:37`), `study-user-queue-users` (`RabbitMQUserService.java:55`). All three delegate to the shared `RabbitMqStudyUserService.receiveStudyUsers` in `shanoir-ng-study-rights`. **Preclinical is not a consumer** despite the brief; it obtains rights indirectly.

Note the orphan: queue `study-user` (`STUDY_USER_QUEUE`) is declared as a bean (`RabbitMQConfiguration.java:543-546`) but bound to nothing and consumed by nobody. It survives only as the (ignored) routing key argument at `StudyUserUpdateBroadcastService.java:44`.

### 4.3 Outbound HTTP

**None.** Every cross-service interaction is RabbitMQ. The only outbound HTTP is Spring's OAuth2 resource server fetching the Keycloak JWK set (`application.yml:90`).

### 4.4 Email side effects

The service never sends mail itself; it enqueues to `users`, which owns SMTP.

- Adding members → `study-user-mail-queue` with recipients = members who opted into `receiveStudyUserReport` (`StudyServiceImpl.java:765-791`).
- Draft study created/edited → `draft-study-mail-queue` to study admins (`StudyServiceImpl.java:793-805`).
- Draft study approved → `approve-study-mail-queue` to all members (`StudyServiceImpl.java:807-820`).
- DUA draft created → `dua-draft-mail-queue` with a caller-supplied recipient address and a link `{front.server.url}/shanoir-ng/dua/view/{uuid}` (`DuaDraftAPIController.java:115-122`).

The `EmailStudy` payload carries the full study description, license, sponsor, principal investigator and scientific advisor (`StudyServiceImpl.java:822-858`) — names of real people crossing a service boundary in a message body. That is not PHI, but it is personal data under GDPR and it is neither redacted nor access-controlled once on the queue.

### 4.5 Shared code from `ms-common`

Consumed heavily: `AbstractEntity`, `IdName`, `StudyUserRight`, `StudyUserInterface`, `StudyUserCommand`/`CommandType`, `RabbitMQConfiguration`, `ShanoirEvent`/`ShanoirEventService`/`ShanoirEventType`, `KeycloakUtil`, `SecurityContextUtil`, `Utils`, `ListDependencyUpdate`, `EqualCheckInterface`, `MDCFilter`, the `shared.exception.*` hierarchy, `shared.email.*`, `shared.dicom.*`, `shared.message.*`, `shared.quality.SubjectQualityTagDTO`, `shared.dto.StudyExaminationsDTO`, `shared.dataset.RelatedDataset`, `shared.subjectstudy.SubjectType`, and the `shanoir-ng-storage` module's `StorageService`.

Duplicated rather than shared: this module re-implements HATEOAS support locally (`shared/hateoas/HalEntity.java`, `Link.java`, `Links.java`) and keeps a local `shared/model/Identifiable.java` and `shared/exception/ShanoirStudiesException.java` that shadow `ms-common` equivalents. `acquisitionequipment/dto/CenterDTO.java` is a second `CenterDTO` alongside `center/dto/CenterDTO.java`.

---

## 5. The authorization / rights model — deep dive

### 5.1 Storage

A right is a row in `study_user` plus rows in the `study_user_study_user_rights` element collection. `StudyUser.studyUserRights` is stored as `List<Integer>` and converted on access (`StudyUser.java:158-177`). `StudyUserRight` (ms-common) enumerates `CAN_SEE_ALL(1)`, `CAN_DOWNLOAD(2)`, `CAN_IMPORT(3)`, `CAN_ADMINISTRATE(4)`. A `confirmed` boolean gates the DUA workflow: a member with an unsigned DUA has rights rows but `confirmed = false` and must be treated as having no rights. An optional `study_user_center` many-to-many narrows a member to specific centers.

### 5.2 Evaluation

Everything funnels into one private predicate:

```605:618:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/security/StudySecurityService.java
    private boolean hasPrivilege(List<StudyUser> studyUserList, StudyUserRight neededRight) {
        if (KeycloakUtil.getTokenRoles().contains("ROLE_ADMIN")) {
            return true;
        }
        Long userId = KeycloakUtil.getTokenUserId();
        if (studyUserList == null) {
            return false;
        }
        StudyUser studyUser = studyUserList.stream().filter(su -> userId.equals(su.getUserId())).findAny().orElse(null);
        if (studyUser == null) {
            return false;
        }
        return studyUser.getStudyUserRights() != null && studyUser.getStudyUserRights().contains(neededRight) && studyUser.isConfirmed();
    }
```

This core is correct: admin bypass, null-safe, and it honours `confirmed`. The defects are all in the ~20 public wrappers around it.

**Center scoping is never evaluated.** `study_user_center` is read and written but no authorization path consults it. `hasPrivilege` does not look at `getCenters()`, and nothing else in the module does either. Center-restricted membership is therefore, today, purely decorative in this service. Whether `datasets` enforces it on the replica is out of scope here, but this service does not.

**`confirmed` is honoured inconsistently.** `hasPrivilege` checks it, `hasRightOnOneStudy` checks it (`:177`), `hasOneStudyToImport` checks it (`StudyUserServiceImpl.java:90`), and the two main study-listing queries check it (`StudyRepository.java:57, 71`). But `findByUserIdAndStudyUserRight` (`StudyRepository.java:94-95`), which backs `GET /studies/studyUser/right/{right}`, does not — a user who has not signed the DUA is still told they hold the right. `getRightsForStudy` and `getRights` (`StudyUserServiceImpl.java:61-84`) likewise return raw rights without the `confirmed` filter, which is what `GET /studies/rights/{studyId}` and `/rights/all` return to the front-end.

**Filtering is done in Java, not SQL, and mostly does not happen.** `findAll()` loads every study the user can see and then re-filters in memory via `@PostFilter`; `findSubjects` loads every subject in the platform and relies on a `@PostAuthorize` that does nothing (§8.1). The only place rights are pushed into SQL is `StudyRepository.java:51-77` and `StudyUserRepository.java:49-50`.

### 5.3 Propagation

```41:49:shanoir-ng-studies/src/main/java/org/shanoir/ng/messaging/StudyUserUpdateBroadcastService.java
    public void broadcast(Iterable<StudyUserCommand> commands) throws MicroServiceCommunicationException {
        try {
            String str = objectMapper.writeValueAsString(commands);
            rabbitTemplate.convertAndSend(RabbitMQConfiguration.STUDY_USER_EXCHANGE, RabbitMQConfiguration.STUDY_USER_QUEUE, str);
            LOG.debug("Brodcasted study-user changes : {}", str);
        } catch (AmqpException | JsonProcessingException e) {
            throw new MicroServiceCommunicationException("Could not send data to study-user-exchange");
        }
    }
```

Every mutation site builds a `List<StudyUserCommand>` (`CREATE` with the full `StudyUser`, `UPDATE` with the full `StudyUser`, `DELETE` with just the id) and calls `broadcast`. Producers: `StudyServiceImpl` create/update/delete/addStudyUser/removeUser (`:166, 266, 745, 867, 887`), `StudyUserServiceImpl` deleteUser/add/remove (`:120, 132, 144`), and `DataUserAgreementService.acceptDataUserAgreement` (`:74`).

### 5.4 Where it goes wrong

1. **Dual write with no coordination.** `broadcast` publishes on the `RabbitTemplate` immediately; the DB transaction commits later. There is no `ChannelTransacted`, no publisher confirm, no transaction synchronization, no outbox. Two failure modes:
   - *Publish then rollback* → the other services grant a right that does not exist in the source of truth. `StudyUserServiceImpl.deleteUser` (`:120-121`) and `removeStudyUserFromStudy` (`:144-145`) explicitly broadcast **before** deleting, so a subsequent constraint failure leaves every replica having revoked a right that is still present locally.
   - *Commit then publish fails* → the exception is caught and logged (`StudyServiceImpl.java:167, 267, 746, 868, 888`; `DataUserAgreementService.java:75`) and the HTTP call returns 200. The rights change is silently invisible platform-wide, with no retry and no alert.
2. **No dead-letter or retry anywhere.** Grepping `shanoir-ng-studies` and `ms-common` for `dead-letter|x-dead|DefaultRequeueRejected|retry` returns only the two container-factory bean definitions (`RabbitMQConfiguration.java:41, 54`). Consumers that throw `AmqpRejectAndDontRequeueException` therefore **drop the message permanently**.
3. **`MicroServiceCommunicationException` discards the cause** (`StudyUserUpdateBroadcastService.java:47`), so the log line has no stack trace for the underlying AMQP fault. The same pattern appears at `SubjectServiceImpl.java:449-450` and `:467`.
4. **`StudyUserCommand.studyUser` is typed as the `StudyUserInterface` interface** (`ms-common/.../StudyUserCommand.java:23`) with no `@JsonTypeInfo`. Serialization writes the concrete fields; deserialization on the consumer side must therefore be configured to a concrete type. This works today but is a latent schema-evolution trap: adding a field to `StudyUser` here silently changes the wire contract for three other services with no versioning.
5. **No reconciliation path.** If a replica drifts (dropped message, consumer down during a burst, poison message), nothing detects or repairs it. There is no "resend all study-users" endpoint or startup sync.
6. **Two of the guards around the model are ineffective.** `studyUsersMatchStudy` (§8.13) and the five `filter*` helpers (§8.1) are no-ops in practice.

---

## 6. Code quality assessment

### 6.1 Transaction management

- **`@Transactional` on private methods — silently ignored.** Spring AOP cannot advise private methods. Four occurrences: `RabbitMQStudiesService.java:324` (`findOrCreateOrAddCenterByInstitutionDicom`), `:353` (`createEquipmentByEquipmentDicom`), `:375` (`getStudyParticipantsTsv`), and `RabbitMQSubjectService.java:163` (`manageSubject`). The last is the worst: subject creation from an AMQP import runs with no transaction at all, since neither `createOrUpdateSubjectWithAMQP` (`:137`) nor `createOrUpdateSubjectWithoutAMQP` (`:151`) is annotated either.
- **`@Transactional` on a self-invoked protected method** — `StudyServiceImpl.updateStudyUsers` (`:627`) is called directly from `update()` at `:416`, bypassing the proxy. It happens to be safe because `update()` is itself transactional, but the annotation is misleading.
- **Two `Transactional` types are mixed.** `jakarta.transaction.Transactional` (JTA) in `StudyServiceImpl.java:90`, `StudyApiController.java:75`, `SubjectApiController.java:49`, `SubjectStudyServiceImpl.java:26`, `StudyUserRepository.java:27`; `org.springframework.transaction.annotation.Transactional` in `SubjectServiceImpl.java:65`, `RabbitMQStudiesService.java:60`, `RelatedDatasetServiceImpl.java:51`. They differ in rollback semantics (`rollbackOn` vs `rollbackFor`, and JTA does not roll back on checked exceptions by default either — but the defaults and the tooling differ). `StudyServiceImpl.update` relies on `@Transactional(rollbackOn = {ShanoirException.class})` (`:312`), which is JTA-specific syntax.
- **`StudyServiceImpl.create` has no `@Transactional` at all** (`:181`). It performs up to three `studyRepository.save` calls (`:228, 243, 251`), N DUA inserts (`:261`), a synchronous RabbitMQ RPC (`:254`), a broadcast, and two mail sends. Any failure part-way leaves a half-created study.
- **`removeUserFromStudy` has no `@Transactional`** (`StudyServiceImpl.java:879`) despite a read-modify-write plus a broadcast.
- **`DataUserAgreementService` has no `@Transactional` on any method.** `acceptDataUserAgreement` (`:60-78`) does two saves and a broadcast non-atomically.

### 6.2 Blocking RPC inside transactions

`StudyServiceImpl.update` is `@Transactional` and calls `updateStudyName` at `:433`, which does `rabbitTemplate.convertSendAndReceive(...)` (`:895`). With `spring.rabbitmq.template.reply-timeout: 60000` (`application.yml:77`), a slow or dead `datasets` service holds a MariaDB write transaction open for a full minute while holding row locks on `study`. The same pattern occurs in `SubjectServiceImpl.update` → `updateSubjectInMicroservices` (`:376` → `:445`) and in `RelatedDatasetServiceImpl.copyData`.

### 6.3 Error handling

- **Swallowed exceptions that produce a success response.** `StudyApiController.uploadDataUseAgreement` (`:477-480`) catches `Exception`, logs, and falls through to `return new ResponseEntity<>(HttpStatus.OK)`. The user is told the DUA uploaded when it did not.
- **`Optional.get()` followed by a dead null check.** `RabbitMQStudiesService.java:211-215` and `:222-226`: `studyRepo.findById(studyId).get()` throws `NoSuchElementException` on a missing study, so the subsequent `if (study != null)` can never be false. `:224` additionally dereferences `study.getProfile()` with no null guard even though `profile` is nullable (`Study.java:140-143`).
- **Catch-and-return-null in an RPC handler.** `RabbitMQSubjectService.updateSubjectStudy` (`:112-118`) has a redundant `catch (NullPointerException)` immediately followed by an identical `catch (Exception)`, both returning `null` to the RPC caller with no error signal.
- **`studySubscription` returns `false` on any error** (`RabbitMQStudiesService.java:269-272`) inside a `@Transactional` method — returning normally, so nothing rolls back.
- **`getDetailedStorageVolumeByStudy` returns `null` on error** (`StudyServiceImpl.java:1002`) while the sibling path returns an empty map (`:998`), and the controller passes the `null` straight into a `ResponseEntity` (`StudyApiController.java:296`).

### 6.4 Null-safety

- `StudyServiceImpl.buildAdminEmailReport` dereferences `study.getExtraDetails()` unconditionally at `:846-847`; `extraDetails` is a nullable `@OneToOne` (`Study.java:200-202`), and `update()` explicitly handles the `existing == null` case at `:344`. A draft study without extra details NPEs on save.
- `StudyServiceImpl.removeUserFromStudy` (`:880-882`) dereferences both `studyUserRepository.findByUserIdAndStudy_Id(...)` (declared to return a bare `StudyUser`, i.e. nullable) and `studyRepository.findById(studyId).orElse(null)`.
- `BIDSServiceImpl.generateParticipantsTsvFile` (`:102-104`) does `.orElse(null)` then `study.getName()`.
- `StudyUser.getStudyId()` (`:143`) dereferences `study` unguarded and is called from `StudyUserServiceImpl.getRights` (`:78`).
- `StudySecurityService.hasRightOnStudy(Study, String)` throws `IllegalArgumentException` on null (`:160-162`), which surfaces as HTTP 500 rather than 403 — reachable from `SubjectStudyApi.java:54` when the body omits `study`.

### 6.5 Dead code and copy-paste

- **`ManufacturerModelRepositoryImpl.findIdsAndNamesForCenter(Long centerId)` ignores its parameter and queries the wrong table**: `SELECT id, name FROM center` (`:45`). It is a copy-paste of `findIdsAndNames` (`:39`) and returns center names where manufacturer-model names are expected. Reachable from `GET /manufacturermodels/centerManuModelsNames/{centerId}`.
- `SubjectRepositoryImpl.findBy(String fieldName, Object value)` (`:40-43`) concatenates `fieldName` straight into JPQL. It is **only** referenced from `SubjectRepositoryTest.java:62` — not reachable from user input today, but it is a loaded gun in a repository interface.
- `StudySecurityService.filterVolumesHasRightOnStudies` (`:138-147`) mutates its argument correctly with `studyIds.removeAll(...)`, proving the intended contract that the other five `filter*` methods fail to honour.
- Three near-identical filter bodies differing only in DTO type (`:406`, `:432`, `:458`) — and all three are broken identically.
- `getTagsToDelete` / `getStudyTagsToDelete` (`StudyServiceImpl.java:514-548`) are the same O(n·m) nested loop twice over.
- `StudyApiController.getUserDir(String)` (`:411-419`) is a public static helper that nothing in the module calls.
- `SubjectApi.java:174` carries the comment `// PostAuthorize removed here: ...` directly beneath the `@PostAuthorize` it claims was removed (`:173`).
- The `challenge` package (96 LOC) exposes `GET /challenges` with no authorization annotation and no test.
- `BIDSServiceImpl.generateParticipantsTsv` (`:86-97`) builds `"attachment;filename" + "participants.tsv"` — a malformed `Content-Disposition` missing the `=`. The method appears unreferenced from any controller.
- `BIDSServiceImpl` pulls in **Joda-Time** (`:24-26`) for an age subtraction that `java.time.Period` does in one line, on a class that already imports `java.time.LocalDate` (`:171`).

### 6.6 Configuration

- `application.yml:34-35` hardcodes the production DB password (`password`), and `:74-75` the RabbitMQ credentials (`guest`/`guest`). These are committed to a public repository.
- `spring.main.allow-circular-references: true` (`:54`, and again `:155`, `:186`) papers over a real dependency cycle rather than breaking it.
- `spring.threads.virtual.enabled: true` (`:62-64`). Virtual threads plus blocking JDBC/AMQP is a plausible source of carrier-thread pinning, and it interacts subtly with the `SecurityContextHolder` `ThreadLocal` that the AMQP listeners write to (§9.4). I have not measured this; flagging it as worth validating rather than asserting a defect.
- `open-in-view: false` (`:46`) is the right setting, but it means any lazy access outside a transaction throws. `StudyApiController.findStudiesLight` (`:168`) is the one list endpoint **without** `@Transactional` while its siblings `findStudies` (`:149`) and `findStudiesNamesAndCenters` (`:186`) have it — a likely `LazyInitializationException` waiting on the `studiesToStudyLightDTOs` mapping.
- `shanoir-ng-nginx/files/etc/nginx/nginx.conf:126` routes `/shanoir-ng/studies/` to port **9900**, but the service listens on **9902** (`application.yml:17`). This file is *not* the deployed one — `docker-compose/Dockerfile:322-331` ships `docker-compose/nginx/shanoir.template.conf`, which correctly targets `:9902` (`:28`). So `shanoir-ng-nginx/files/` is stale dead configuration that will mislead the next person who greps for the gateway config.

---

## 7. Test coverage analysis

### 7.1 Numbers

52 files under `src/test`, of which 49 contain tests (`TestConfiguration`, `ModelsUtil`, `KeycloakControllerTestIT` are helpers) — **≈256 `@Test` methods**.

| Style | Classes | Notes |
|---|---|---|
| `@SpringBootTest` | 31 | full context; includes all `*SecurityTest`, `*TestIT`, `*MapperTest` |
| `@WebMvcTest` | 7 | one per `*ApiController` |
| `@DataJpaTest` | 7 | repository tests on H2 |
| `@ExtendWith(MockitoExtension.class)` | 3 | `AcquisitionEquipmentServiceTest`, `CoilServiceTest`, `ManufacturerModelServiceTest` |
| none | 1 | `UtilsTest` |

### 7.2 Per-package coverage map

| Package | Coverage | Comment |
|---|---|---|
| `center`, `coil`, `manufacturermodel` | **good** | 6, 6 and 9 classes each: controller, IT, mapper, repository, security, service. These three trivial CRUD packages hold ~40% of the suite. |
| `acquisitionequipment` | good | 5 classes |
| `study` (service/security/controller) | partial | 9 classes but with real gaps — see below |
| `subject` | partial | 7 classes |
| `subjectstudy` | thin | mapper + repository + one API security test |
| `studycenter`, `timepoint` | mapper only | |
| **`dua` (DuaDraft)** | **ZERO** | the unauthenticated endpoints of §8.2 |
| **`study.dua` (`DataUserAgreementService`)** | **ZERO** | the entire DUA signature workflow |
| **`messaging` (`StudyUserUpdateBroadcastService`)** | **ZERO** | the platform's rights broadcast |
| **`study.service.StudyUserServiceImpl`** | **ZERO** | `deleteUser` listener, add/remove member |
| **`study.service.RelatedDatasetServiceImpl`** | **ZERO** | copy-datasets, 278 LOC |
| **`configuration.amqp.RabbitMQStudiesService`** | **ZERO** | 11 listeners, 397 LOC |
| **`tag`, `profile`, `key`, `bids`, `challenge`, `studyexamination`, `shared.common`** | **ZERO** | |
| `study.security.StudySecurityService` | **partial and misleading** | `StudySecurityTest` (8 tests) only exercises `findAll()`; the five broken `filter*` methods, `hasRightOnSubjects`, `hasRightOnCopy` and `checkUserOnDUA` have **no test at all** |

A grep for any test referencing `filterSubject|filterStudy|filterSimple|hasRightOnSubjects|hasRightOnCopy|DuaDraft|RelatedDataset|StudyUserServiceImpl|StudyUserUpdateBroadcastService|RabbitMQStudiesService|DataUserAgreementService` matches only two files, and in both cases only as a Mockito `@Mock` field declaration.

### 7.3 Test quality

The `*SecurityTest` classes are the strongest thing in the suite — `SubjectApiSecurityTest` has 55 assertions across 4 tests, `StudyApiSecurityTest` 41, `StudySecurityTest` 39 — and they systematically walk anonymous → user → expert → admin. The `*MapperTest` classes at the other end average 2 tests and 5 assertions and mostly verify that MapStruct copies an id.

Specific defects found in the test code itself:

- **Assertions that can never fire.** `StudyServiceTest.java:251` and `:254` compare a `Long` to a `String`: `su.getId().equals("1L")`. Both branches are dead, so the four assertions they guard (`:252-253`, `:256`) never execute. The sibling test does it correctly at `:285`/`:288` — the two were clearly copy-pasted and one was half-fixed.
- **A test with zero assertions.** `StudyServiceTest.updateStudyUsersTest` (`:196-218`) sets up an elaborate fixture and then just calls `studyService.update(updated)`. It passes as long as nothing throws.
- **A tautological assertion.** `StudyServiceTest.java:250`: `assertEquals(suToBeAdded, su)` where `su` *is* `suToBeAdded` (same object reference, taken from the same list).
- **Stubbing a real object.** `StudyServiceTest.java:186` and `:215` call `given(studyService.updateStudyName(...))` where `studyService` is `@InjectMocks` — a real `StudyServiceImpl`, not a mock. The call actually executes, reaching `rabbitTemplate.convertSendAndReceive(...)`, and Mockito ends up stubbing *that* invocation instead. It works by accident and will break unrecognisably the moment `updateStudyName`'s body changes.
- **`@SpringBootTest` used to run pure Mockito unit tests.** `StudyServiceTest` (`:73`) boots the whole application context and then ignores it, testing a hand-wired `StudyServiceImpl`. Consequence: `@PreAuthorize` is not applied, so none of these tests cover the security layer even though they carry `@WithMockKeycloakUser` annotations that suggest they do.
- **Every test id is below 128.** `StudyServiceSecurityTest` uses ids 1L, 2L, 3L throughout (`:58-60`, `:206`). Those `Long`s come from the `Long.valueOf` cache, so reference comparison and value comparison agree — which is precisely why the `!=`-on-`Long` bug in `studyUsersMatchStudy` (§8.13) is invisible to the suite. The one test that does exercise that guard (`:156-160`) only covers the *different-id* case.

### 7.4 Highest-value missing tests

1. `StudySecurityServiceTest` covering all five `filter*` methods, asserting on the **caller's** list contents after invocation. This single test class catches §8.1.
2. A `@WebMvcTest`/`@SpringBootTest` asserting that `GET /subjects` as a `USER` who is a member of study A returns only study-A subjects.
3. A security test asserting `PUT /dua/{id}` and `GET /dua/{id}` return 401 for an anonymous caller (§8.2).
4. `hasRightOnSubjects` with subjects spanning two studies where the user has the right in only one — must return `false` (§8.4).
5. `POST /subjects` with `study.id` = permitted study and `subjectStudyList[0].study.id` = victim study — must be rejected (§8.3).
6. `PUT /subjectStudy/{id}` where the body's study differs from the persisted subject-study's study — must be rejected (§8.5).
7. `StudyUserUpdateBroadcastServiceTest` + a `RabbitMQStudiesServiceTest` asserting redelivery idempotency for `linkExamination` (§8.13).
8. `DataUserAgreementServiceTest` for the accept flow: `confirmed` flips, a single `UPDATE` command is broadcast, and a broadcast failure does not leave the DUA accepted silently.
9. `StudyUserServiceImplTest.findStudyUsersByStudyId` asserting each `StudyUser` gets *its own* centers (§8.7).
10. A `@DataJpaTest` proving `findByUserIdAndStudyUserRight` excludes unconfirmed members (`StudyRepository.java:94`).

---

## 8. Bugs & correctness risks

| # | Severity | Finding | Location |
|---|---|---|---|
| 8.1 | **Critical** | Five `filter*` security helpers are no-ops; `GET /subjects` leaks all subjects | `StudySecurityService.java:420,446,472,499,522` |
| 8.2 | **Critical** | `/dua/**` permitAll + no method guard → unauthenticated read/write of DUA drafts | `SecurityConfiguration.java:76`, `DuaDraftAPI.java:58,71` |
| 8.3 | **Critical** | Subject-create authz checks `study` but service persists `subjectStudyList[0].study` | `StudySecurityService.java:350`, `SubjectServiceImpl.java:293-298` |
| 8.4 | **High** | `hasRightOnSubjects` is any-of, not all-of; fails open on empty | `StudySecurityService.java:283-295` |
| 8.5 | **High** | `PUT /subjectStudy` checks rights on body study, mutates DB entity | `SubjectStudyApi.java:53`, `SubjectStudyServiceImpl.java:52` |
| 8.6 | **High** | `updateSubjectValues` reassigns `study` from the request | `SubjectServiceImpl.java:401` |
| 8.7 | **High** | Every `StudyUser` receives the union of all study centers | `StudyUserServiceImpl.java:101` |
| 8.8 | **High** | Rights broadcast: dual write, publish-before-commit, swallowed failures, no DLQ | `StudyUserServiceImpl.java:120`, `StudyServiceImpl.java:744` |
| 8.9 | **Medium** | `GET /studies/studyUser/{studyId}` open to any authenticated user | `StudyApi.java:409` |
| 8.10 | **Medium** | `GET /studies/dua-download/{studyId}/{fileName}` has no study-right check | `StudyApi.java:359` |
| 8.11 | **Medium** | `POST /common` resolves any subject/study/center name by id | `CommonApi.java:37`, `CommonServiceImpl.java:38` |
| 8.12 | **Medium** | `uploadDataUseAgreement` swallows all errors and returns 200 | `StudyApiController.java:477` |
| 8.13 | **Medium** | `studyUsersMatchStudy` uses `!=` on boxed `Long` and is vacuous under `@JsonIgnore` | `StudySecurityService.java:548` |
| 8.14 | **Medium** | `@Transactional` on private/self-invoked methods — silently inert | `RabbitMQStudiesService.java:324,353,375`; `RabbitMQSubjectService.java:163` |
| 8.15 | **Medium** | Operator-precedence bug + latent NPE in subject/preclinical filter | `SubjectServiceImpl.java:497-498` |
| 8.16 | **Medium** | Non-idempotent AMQP listeners; `AmqpRejectAndDontRequeue` with no DLQ | `RabbitMQStudiesService.java:147,151` |
| 8.17 | **Medium** | Caller-supplied `taskId` overwrites the `ShanoirEvent` id | `RelatedDatasetServiceImpl.java:103-107` |
| 8.18 | **Medium** | `findByUserIdAndStudyUserRight` ignores `confirmed` | `StudyRepository.java:94-95` |
| 8.19 | **Low** | `findIdsAndNamesForCenter` returns centers, ignores its parameter | `ManufacturerModelRepositoryImpl.java:44-46` |
| 8.20 | **Low** | `file.getName()` used where `getOriginalFilename()` is meant | `StudyApiController.java:466` |
| 8.21 | **Low** | NPEs: `getExtraDetails()`, `removeUserFromStudy`, `Optional.get()` | `StudyServiceImpl.java:846,880`; `RabbitMQStudiesService.java:211` |
| 8.22 | **Low** | `createAutoIncrement` name generation races and can `NumberFormatException` | `SubjectServiceImpl.java:245-250` |
| 8.23 | **Low** | `hasAnyRightOnStudy(Long)` lacks the admin short-circuit its sibling has | `StudySecurityService.java:117` |

### 8.1 — Critical: the `filter*` security helpers do nothing

```406:422:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/security/StudySecurityService.java
    public boolean filterSubjectDTOsHasRightInOneStudy(List<SubjectDTO> dtos, String rightStr) {
        if (dtos == null) {
            return true;
        }
        List<SubjectDTO> newList = new ArrayList<>();
        Map<Long, SubjectDTO> map = new HashMap<>();
        for (SubjectDTO dto : dtos) {
            map.put(dto.getId(), dto);
        }
        for (Subject subject : subjectRepository.findAllById(new ArrayList<>(map.keySet()))) {
            if (hasRightOnTrustedSubjectForOneStudy(subject, rightStr)) {
                newList.add(map.get(subject.getId()));
            }
        }
        dtos = newList;
        return true;
    }
```

**What's wrong:** `dtos = newList` assigns to the local parameter reference. Java is pass-by-value; the caller's list is untouched. The method computes the correct answer, throws it away, and returns an unconditional `true`. Identical bodies at `:432-448`, `:458-474`, `:484-501` and `:511-524`.

**How it manifests:** `GET /subjects` is annotated

```70:76:shanoir-ng-studies/src/main/java/org/shanoir/ng/subject/controler/SubjectApi.java
    @PreAuthorize("hasAnyRole('ADMIN', 'EXPERT', 'USER')")
    @PostAuthorize("hasRole('ADMIN') or @studySecurityService.filterSubjectDTOsHasRightInOneStudy(returnObject.getBody(), 'CAN_SEE_ALL')")
    ResponseEntity<List<SubjectDTO>> findSubjects(
```

and the controller behind it calls `subjectService.findAll()` (`SubjectApiController.java:96`) → `subjectRepository.findAll()` (`SubjectServiceImpl.java:151`) with no study scoping whatsoever. So **any authenticated `USER` receives every subject row in the platform**, mapped to `SubjectDTO`: name (the pseudonymised common name), `identifier`, `imagedObjectCategory`, hemispheric dominance, sex, tags. Across the OFSEP/Neurinfo deployments that is a complete cross-study subject roster.

`filterStudyIdNameDTOsHasRight` is additionally mis-wired: it is used with `@PostFilter` (`StudyService.java:76`), which invokes the expression **once per element** with `filterObject` bound to a single `IdName`, against a method signature expecting `List<IdName>`. I could not confirm statically whether Spring's SpEL resolver coerces or throws here; either way the expression cannot be doing what its author intended.

**Fix:** change the contract to `List<X> filter(...)` returning the filtered list and use `@PostFilter` element-wise predicates instead, or mutate in place as `filterVolumesHasRightOnStudies` (`:145`) already does: `dtos.retainAll(newList)`. Then push the scoping into SQL so the rows never leave the database — `findSubjects` should take the caller's study ids as a query parameter.

### 8.2 — Critical: unauthenticated DUA-draft endpoints

```75:80:shanoir-ng-studies/src/main/java/org/shanoir/ng/configuration/security/SecurityConfiguration.java
                .authorizeHttpRequests(
                    matcher -> matcher.requestMatchers("/studies/public/data", "/swagger-ui.html", "/swagger-ui/**", "/api-docs/**", "/dua/**")
                        .permitAll()
                    .anyRequest()
                        .authenticated()
                )
```

`DuaDraftAPI` is mapped at `@RequestMapping("/dua")` (`:36`). Its `POST` carries `@PreAuthorize(... CAN_ADMINISTRATE)` (`:47`), but `PUT /dua/{duaId}` (`:58-63`) and `GET /dua/{duaId}` (`:71-73`) carry **no annotation**, and the filter chain has already waved them through.

**How it manifests:** anyone on the network can `GET /shanoir-ng/studies/dua/{uuid}` to read a draft (study id, study name, url, funding, thanks, papers — `dua/model/DuaDraft.java:23-36`) and, worse, `PUT` to overwrite it. `DuaDraftServiceImpl.update` (`:62-71`) preserves only `studyId`/`studyName`; every other field is caller-controlled. Since this is the text of a data-use agreement being prepared for an external signatory, silent tampering has legal weight. Neither endpoint emits a `ShanoirEvent`, so there is no audit trail of the change.

The design intent is evidently capability-based: the id is a `UUID.randomUUID()` (`DuaDraftServiceImpl.java:52`) mailed as a link (`DuaDraftAPIController.java:117`) to someone with no Shanoir account. That is a defensible pattern, but as implemented the capability never expires, cannot be revoked, is not rate-limited, grants **write** as well as read, and travels in a URL (so it lands in browser history, referrer headers and nginx access logs).

**Fix:** at minimum split read from write — make `PUT` require a signed, single-use, expiring token rather than the bare draft id, and log both operations as `ShanoirEvent`s. Narrow the `permitAll` matcher to `GET /dua/{id}` only.

### 8.3 — Critical: subject-creation authorization bypass

The guard:

```345:361:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/security/StudySecurityService.java
    public boolean hasRightOnTrustedSubjectForOneStudy(Subject subject, String rightStr) {
        if (subject == null || rightStr == null) {
            return false;
        }
        StudyUserRight right = StudyUserRight.valueOf(rightStr);
        if (subject.getStudy() != null) {
            return hasPrivilegeOnStudy(subject.getStudy().getId(), right);
        }
        // @todo: remove later usage of subject study list
        if (subject.getSubjectStudyList() != null) {
            return subject.getSubjectStudyList().stream()
                    .map(SubjectStudy::getStudy)
                    .map(Study::getId)
                    .allMatch(studyId -> hasPrivilegeOnStudy(studyId, right));
        }
        return false;
    }
```

The persistence path:

```293:299:shanoir-ng-studies/src/main/java/org/shanoir/ng/subject/service/SubjectServiceImpl.java
        if (subjectStudyList != null && !subjectStudyList.isEmpty()) {
            if (subjectStudyList.size() > 1) {
                throw new ShanoirException("A subject is only in one study.", HttpStatus.FORBIDDEN.value());
            }
            SubjectStudy subjectStudy = subjectStudyList.get(0);
            subject = mapSubjectStudyAttributesToSubject(subject, subjectStudy);
```

where `mapSubjectStudyAttributesToSubject` does `subject.setStudy(subjectStudy.getStudy())` (`:334`).

**What's wrong:** the check gives `study` priority and returns early; the writer gives `subjectStudyList` priority and overwrites `study`. The two disagree on which field is authoritative.

**How it manifests:** a `USER` with `CAN_IMPORT` on study 5 posts to `/subjects`:

```json
{ "name": "X", "study": {"id": 5},
  "subjectStudyList": [ {"study": {"id": 99}, "subjectType": 1} ] }
```

`hasRightOnTrustedSubjectForOneStudy` sees `study.id = 5`, confirms `CAN_IMPORT`, returns true. `mapSubjectStudyListToSubject` then rewrites `subject.study` to 99 and persists the subject into study 99. This endpoint is explicitly a ShanoirUploader entry point (`SubjectApi.java:122`), so it is exercised by a non-browser client and the payload shape is not constrained by the Angular front-end. (I have confirmed this by reading both code paths; I have not executed it.)

**Fix:** make `hasRightOnTrustedSubjectForOneStudy` resolve the effective study with exactly the same precedence rule as `mapSubjectStudyListToSubject`, or better, normalise the payload in one place before the security check runs and reject requests that specify both fields inconsistently.

### 8.4 — High: `hasRightOnSubjects` is "any-of" and fails open

```283:295:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/security/StudySecurityService.java
    public boolean hasRightOnSubjects(List<Long> subjectIds, String rightStr) throws EntityNotFoundException {
        List<Long> studyIds = Utils.toList(studyRepository.findStudyIdsBySubjectIds(subjectIds));
        if (studyIds == null || studyIds.isEmpty()) {
            return true;
        }
        List<StudyUser> studyUserList = new ArrayList<>();
        for (Long studyId : studyIds) {
            studyUserList.addAll(studyUserRepository.findByStudy_Id(studyId));
        }

        StudyUserRight right = StudyUserRight.valueOf(rightStr);
        return !studyUserList.isEmpty() && hasPrivilege(studyUserList, right);
    }
```

Two defects. First, all studies' `StudyUser` rows are flattened into one list and handed to `hasPrivilege`, whose `findAny()` (`:613`) picks an arbitrary row matching the current user. So holding the right in **one** of the studies satisfies the check for **all** of them — and which row wins is non-deterministic when the user is a member of several. Second, `studyIds.isEmpty()` returns `true`: if `subjectIds` is null or references nothing, the check passes. `CopyData.getSubjectIds()` returns `null` when `subjects` is absent (`CopyData.java:59-64`), which reaches this path.

This is the guard behind `POST /studies/copyDatasets` via `hasRightOnCopy` (`:632`), i.e. the operation that physically duplicates imaging data between studies.

**Fix:** iterate per study and require *every* study to grant the right; treat an empty study set as `false`.

### 8.5 — High: `PUT /subjectStudy` confused deputy

```53:56:shanoir-ng-studies/src/main/java/org/shanoir/ng/subjectstudy/controler/SubjectStudyApi.java
    @PreAuthorize("(hasRole('ADMIN') or (hasAnyRole('EXPERT', 'USER')"
            + "  and (@studySecurityService.hasRightOnStudy(#subjectStudy.getStudy(), 'CAN_IMPORT')"
            + " or @studySecurityService.hasRightOnStudy(#subjectStudy.getStudy(), 'CAN_ADMINISTRATE') )"
            + "  )) and @controllerSecurityService.idMatches(#subjectStudyId, #subjectStudy)")
```

The rights check reads the study **out of the request body**. `hasRightOnStudy(Study, String)` does re-resolve it against the DB (`StudySecurityService.java:159-164`), so the *rights* are genuine — but they are the rights on whatever study the caller nominated, not on the study that actually owns the subject-study being edited. `SubjectStudyServiceImpl.update` (`:52-58`) then loads the row by `subjectStudyNew.getId()` and mutates `physicallyInvolved`, `subjectStudyIdentifier`, `subjectType` and the tag list, never comparing `subjectStudyOld.getStudy()` to the body's study. `idMatches` only compares the path id to the body id.

**Fix:** derive the study from the persisted `SubjectStudy` and check rights on that, e.g. a `hasRightOnSubjectStudy(#subjectStudyId, 'CAN_IMPORT')` helper.

### 8.6 — High: subject update silently reassigns the study

```388:401:shanoir-ng-studies/src/main/java/org/shanoir/ng/subject/service/SubjectServiceImpl.java
        subjectOld.setUserPersonalCommentList(subjectNew.getUserPersonalCommentList());
        // We can not update the study: attention: created exams contain study id
        subjectOld.setStudyIdentifier(subjectNew.getStudyIdentifier());
        subjectOld.setSubjectType(subjectNew.getSubjectType());
        if (subjectNew.getTags() != null) {
            subjectOld.setTags(subjectNew.getTags());
            for (Tag tagOld : subjectOld.getTags()) {
                tagOld.setStudy(subjectNew.getStudy());
            }
        }

        subjectOld.setPhysicallyInvolved(subjectNew.isPhysicallyInvolved());
        subjectOld.setQualityTag(subjectNew.getQualityTag());
        subjectOld.setStudy(subjectNew.getStudy());
```

Line 401 does exactly what the comment on line 389 says must not happen, and line 395 additionally re-parents the subject's tags to the new study. The `@PreAuthorize` on `PUT /subjects/{subjectId}` (`SubjectApi.java:146`) checks `CAN_IMPORT` on the subject's *current* study only, so a user with import rights in study A can move a subject — and therefore, per the comment, desynchronise it from examinations that still carry the old study id — into any study, including one they cannot see.

**Fix:** drop line 401 (and the tag re-parenting), or gate a deliberate "move subject" operation behind `CAN_ADMINISTRATE` on both source and target.

### 8.7 — High: every `StudyUser` gets every center

```97:103:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/service/StudyUserServiceImpl.java
    @Override
    public List<StudyUser> findStudyUsersByStudyId(Long studyId) {
        List<StudyUser> studyUsers = studyUserRepository.findByStudy_Id(studyId);
        // two bags contraint on EntityGraph expression in findByStudy_Id: load centers manually
        studyUsers.stream().forEach(su -> su.setCenters(studyUserRepository.findDistinctCentersByStudyId(studyId)));
        return studyUsers;
    }
```

`findDistinctCentersByStudyId` is `SELECT DISTINCT su.centers FROM StudyUser su WHERE su.study.id = :studyId` (`StudyUserRepository.java:43-44`) — the union of the centers of *all* members of the study. The loop assigns that same union to each `StudyUser`. It is also an N+1: the identical query runs once per member.

**How it manifests:** `GET /studies/studyUser/{studyId}` (`StudyApiController.java:572`) reports every member as scoped to every center. Because `StudyUser` serialises `centerIds` (`StudyUser.java:211`) while hiding `centers` (`:207`), a front-end that reads this list and posts it back through `PUT /studies/{studyId}` will persist the widened scope — `updateStudyUsers` copies `replacingSu.getCenters()` verbatim (`StudyServiceImpl.java:697`). I have not traced the Angular code to confirm that round-trip actually happens, so treat the persistence half as a risk rather than a confirmed exploit; the display half is certain.

**Fix:** load each member's own centers, ideally with a single `WHERE su.study.id = :studyId` query returning `(studyUserId, center)` pairs grouped in memory.

### 8.8 — High: the rights broadcast is an unguarded dual write

Covered in detail in §5.4. The three concrete code shapes:

*Publish before delete* — `StudyUserServiceImpl.java:120-121`:
```java
            this.studyUserUpdateBroadcastService.broadcast(commands);
            this.studyUserRepository.deleteAll(sus);
```
*Publish inside a transaction that may still roll back* — `StudyUserServiceImpl.java:130-133`.

*Swallow the failure and return success* — `StudyServiceImpl.java:744-748`:
```java
            studyUserCom.broadcast(commands);
        } catch (MicroServiceCommunicationException e) {
            LOG.error("Could not transmit study-user update info through RabbitMQ", e);
        }
```

**Fix (incremental):** (a) move every `broadcast` into a `TransactionSynchronization.afterCommit` callback so nothing is published unless the DB committed; (b) enable publisher confirms and stop swallowing the exception — a failed rights propagation must fail the request; (c) add a `study_user_outbox` table drained by a scheduled poller for durability; (d) add a reconciliation endpoint that replays the full `study_user` table on demand.

### 8.9 / 8.10 / 8.11 — Medium: three endpoints missing study-level checks

- `GET /studies/studyUser/{studyId}` — `@PreAuthorize("hasRole('ADMIN') or (hasAnyRole('EXPERT', 'USER'))")` (`StudyApi.java:409`). Any authenticated user enumerates the membership of any study: user ids, usernames, rights, and (per §8.7) center scopes. Compare with the sibling `POST`/`DELETE` on the same path, which both require `CAN_ADMINISTRATE`.
- `GET /studies/dua-download/{studyId}/{fileName}/` — `@PreAuthorize("hasAnyRole('ADMIN', 'EXPERT', 'USER')")` (`StudyApi.java:359`), while the parallel `protocol-file-download` correctly demands `CAN_DOWNLOAD` (`:293`). Any user can fetch any study's DUA PDF given its filename. `fileName` is a `{fileName:.+}` path variable passed straight to `storageService.loadStudyData(studyId, fileName)` (`StudyApiController.java:488`) — whether traversal is possible depends on `shanoir-ng-storage`, which I did not audit; it should be checked.
- `POST /common` — no `@PreAuthorize` at all (`CommonApi.java:37`). `CommonServiceImpl.findByIds` resolves an arbitrary `studyId`, `centerId`, `subjectId` and `equipementId` to their names/serial numbers with no rights check, giving any authenticated user an id→name oracle over the entire subject table.

### 8.12 — Medium: DUA upload reports success on failure

```460:481:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/controler/StudyApiController.java
        try {
            if (!file.getOriginalFilename().endsWith(PDF_EXTENSION) || file.getSize() > 50000000) {
                ...
                return new ResponseEntity<>(HttpStatus.NOT_ACCEPTABLE);
            }
            storageService.storeStudyData(...);
        } catch (Exception e) {
            LOG.error("Error while loading files on study: {}. File not uploaded.", studyId, e);
        }
        return new ResponseEntity<>(HttpStatus.OK);
```

Any storage failure returns `200 OK` with the log line literally saying "File not uploaded". Meanwhile `study.dataUserAgreementPaths` may already reference the missing file, so members are asked to sign a document that cannot be served. Note also line 466 inside the rejection branch: `study.getDataUserAgreementPaths().remove(file.getName())` — `MultipartFile.getName()` returns the *form field* name, not the filename, so the cleanup never removes anything (`getOriginalFilename()` is what's meant, as used two lines up).

### 8.13 — Medium: `studyUsersMatchStudy` is both wrong and vacuous

```546:552:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/security/StudySecurityService.java
    public boolean studyUsersMatchStudy(Study study) {
        for (StudyUser su : study.getStudyUserList()) {
            if (su.getStudy() != null && su.getStudy().getId() != null && su.getStudy().getId() != study.getId())
                return false;
        }
        return true;
    }
```

Two problems. (a) `su.getStudy().getId() != study.getId()` compares `Long` **references**. For ids above 127 two equal values are distinct objects, so the comparison is `true` and the guard denies a legitimate request; below 128 the `Long` cache makes it accidentally correct — which is why the test suite, whose ids are 1, 2 and 3, never sees it (§7.3). (b) In the only path that matters — `PUT /studies/{studyId}` via `StudyService.java:116` — `StudyUser.study` is `@JsonIgnore` (`StudyUser.java:72-74`), so after deserialization `su.getStudy()` is `null`, the condition short-circuits, and the method returns `true` unconditionally. The guard that is supposed to stop a caller from re-parenting study-users to another study does nothing on the request path it was written for.

**Fix:** use `.equals()`, and validate against the path variable `studyId` rather than a body field that Jackson never populates.

### 8.14 — Medium: inert `@Transactional`

`@Transactional` on `private` methods cannot be applied by Spring's proxy-based AOP: `RabbitMQStudiesService.java:324` (`findOrCreateOrAddCenterByInstitutionDicom`), `:353` (`createEquipmentByEquipmentDicom`), `:375` (`getStudyParticipantsTsv`), `RabbitMQSubjectService.java:163` (`manageSubject`). The first two create `Center`/`AcquisitionEquipment` rows during DICOM import with no transaction; the fourth creates `Subject` rows the same way. `StudyServiceImpl.updateStudyUsers` (`:627`) is `protected` and self-invoked from `:416` — inert, though harmlessly so because the caller is transactional.

### 8.15 — Medium: operator precedence in the preclinical filter

```497:498:shanoir-ng-studies/src/main/java/org/shanoir/ng/subject/service/SubjectServiceImpl.java
                if (studyId.equals(rel.getStudy().getId())
                        && preclinical == null || (preclinical.equals(rel.getSubject().isPreclinical()))) {
```

`&&` binds tighter than `||`, so this parses as `(studyIdMatches && preclinical == null) || preclinical.equals(...)`. The author clearly meant `studyIdMatches && (preclinical == null || preclinical.equals(...))`. Consequences: when `preclinical != null` the study-id check is skipped entirely; when `preclinical == null` and the study-id check fails, the right operand runs and NPEs on `preclinical.equals(...)`. Today `subjectStudyList` is fetched by `studyId` so the left conjunct is always true and the bug is latent — but it is one query change away from being live.

Separately, line 483 selects via `findByStudyIdAndStudy_StudyUserList_UserId(studyId, userId)`, i.e. bare membership, without checking `CAN_SEE_ALL` or `confirmed`. A member with only `CAN_IMPORT`, or one who has not signed the DUA, still sees the full subject list of the study.

### 8.16 — Medium: non-idempotent listeners, no DLQ

`addExaminationToStudy` (`StudyServiceImpl.java:904-921`) adds a freshly constructed `StudyExamination` to `study.getExaminations()`, a `HashSet`. `StudyExamination` inherits `AbstractEntity`, which defines no `equals`/`hashCode`, so the set uses identity and a redelivered `CREATE_EXAMINATION_EVENT` inserts a duplicate row. The bulk sibling `insertOneBatch` gets this right with a `LEFT JOIN ... WHERE se.id IS NULL` anti-join (`StudyExaminationBulkRepositoryImpl.java:76-79`) — the single-message path should use the same guard.

Every listener that fails throws `AmqpRejectAndDontRequeueException` (e.g. `RabbitMQStudiesService.java:151, 182, 203, 297, 320, 349, 371`). With no `x-dead-letter-exchange` configured anywhere in `ms-common`'s `RabbitMQConfiguration`, those messages are discarded. A transient DB blip during an import silently loses the examination→study link, and nothing surfaces it.

### 8.17 — Medium: caller-controlled event id

```103:107:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/service/RelatedDatasetServiceImpl.java
        if (copyData.getTaskId() != null) {
            // if taskId is provided, it means that the copy process has already been started and we are in
            // the context of a batch copy
            event.setId(copyData.getTaskId());
        }
```

`taskId` comes straight from the `POST /studies/copyDatasets` request body with no validation that it belongs to the caller or to any in-flight batch. A caller can attach their copy progress to an arbitrary event id, overwriting another user's task status.

Also in this file: `dto.setUserRole(KeycloakUtil.getUserRole())` (`:267`) ships the caller's role across the queue for `datasets` to act on. Trusting a role asserted in a message body is a pattern worth revisiting platform-wide.

### 8.18 — Medium: `confirmed` ignored in one rights query

```94:95:shanoir-ng-studies/src/main/java/org/shanoir/ng/study/repository/StudyRepository.java
    @Query("SELECT su.study.id FROM StudyUser su WHERE su.userId = :userId AND :right MEMBER OF su.studyUserRights")
    List<Long> findByUserIdAndStudyUserRight(Long userId, Integer right);
```

No `su.confirmed = true`, unlike `findDistinctStudyIdByUserId` (`StudyUserRepository.java:49`) which gets it right. Backs `GET /studies/studyUser/right/{right}`, so a user with an unsigned DUA is told they hold the right in that study.

### 8.19–8.23 — Low

- **8.19** `ManufacturerModelRepositoryImpl.findIdsAndNamesForCenter` ignores `centerId` and selects from `center` (`:44-46`).
- **8.20** `file.getName()` vs `getOriginalFilename()` (`StudyApiController.java:466`) — see §8.12.
- **8.21** NPEs at `StudyServiceImpl.java:846-847` (null `extraDetails` on a draft study), `:880-882` (null `StudyUser`/`Study`), `RabbitMQStudiesService.java:211, 222` (`Optional.get()` plus a dead null check), `BIDSServiceImpl.java:102-104`.
- **8.22** `createAutoIncrement` (`SubjectServiceImpl.java:245-250`) reads the max existing subject name for a center, parses the numeric suffix and increments — a classic read-modify-write race under concurrent import. The `(name, study_id)` unique index catches it, but unlike `create` (`:221-223`) this method does not catch `DataIntegrityViolationException`, so the caller gets a 500. `Integer.parseInt` at `:248` also throws if any existing subject name in that center does not match the expected `NNN` + `NNNN` shape.
- **8.23** `hasAnyRightOnStudy(Long studyId)` (`:117-127`) has no `ROLE_ADMIN` short-circuit, while the varargs overload directly above it does (`:96-98`). An admin who is not a `StudyUser` of the study fails the check behind `GET /subjects/nameExists/{name}/inStudy/{studyId}`.

---

## 9. Security & data-protection review

### 9.1 Access control

The `@PreAuthorize`/`@PostAuthorize` discipline is applied broadly and the core `hasPrivilege` predicate is sound. The failures are at the edges, and they cluster into four recognisable patterns:

1. **Guards that silently do nothing** — §8.1 (five filters), §8.13 (`studyUsersMatchStudy`).
2. **Guards that check a different object than the one being written** — §8.3 (subject create), §8.5 (subject-study update).
3. **Guards that are simply absent** — §8.2 (`/dua`), §8.9 (`studyUser` listing), §8.10 (`dua-download`), §8.11 (`/common`), `GET /bids/neurobagel/studyId/{studyId}`, `GET /challenges`, `GET /studies/statistics/{studyId}` (role-only: any `EXPERT` gets per-subject statistics for any study).
4. **Guards that disagree with each other** — API layer vs service layer on the same operation; `confirmed` honoured in some queries and not others; `ROLE_ADMIN` short-circuited in one overload and not its neighbour.

Pattern 1 is the dangerous one because the code *looks* protected. A reviewer scanning annotations sees `@PostAuthorize("...filterSubjectDTOs...")` and moves on.

### 9.2 PHI / PII exposure

- `Subject` stores `birthDate`, `identifier` and `PseudonymusHashValues` in clear (`Subject.java:72, 88, 91`). `SubjectDTO` is what §8.1 leaks wholesale.
- `EmailStudy` carries sponsor, principal investigator and scientific advisor names onto `draft-study-mail-queue` (`StudyServiceImpl.java:853-855`).
- `RabbitMQStudiesService.java:280` logs the entire quality-tag message at INFO: `LOG.info(messageStr)` — a JSON array of subject ids and their QC tags, written to `/var/log/shanoir-ng-logs/shanoir-ng-studies.log` on every batch.
- `SubjectServiceImpl.java:225` logs subject id and name at INFO on every creation. The name is the pseudonymised common name rather than a patient name, so this is low-risk, but it is a per-subject audit-grade record sitting in an application log with no retention policy visible in `logback-spring.xml`.
- `BIDSServiceImpl.ageCalculation` (`:170-179`) derives exact age in years from the stored birth date into `participants.tsv`. That is conventional for BIDS, but the file is generated on demand via `study-participants-tsv` with no rights check inside this service (the listener asserts `ROLE_ADMIN` on itself — `:367`).

### 9.3 Injection

No SQL injection was found in reachable code. `StudyExaminationBulkRepositoryImpl` builds dynamic SQL but binds every value as a `?` placeholder (`:62-67`); only the `UNION ALL` scaffolding is concatenated. `StudyRepositoryImpl` uses a properly parameterised `StoredProcedureQuery` (`:42-48`). The one dynamic-JPQL construct, `SubjectRepositoryImpl.findBy(String fieldName, ...)` (`:40-43`), concatenates a caller-supplied field name but is referenced only from a test.

### 9.4 Audit trail

`ShanoirEventService` is used for study create/update/delete and subject create/update/delete, which is good. Three gaps:

- **Rights changes are not audited as such.** Adding, removing or re-scoping a `StudyUser` produces a generic `UPDATE_STUDY_EVENT` (`StudyApiController.java:542-548`) or, in the `PUT /studies/{studyId}` path, nothing that identifies *which* rights changed. For a platform where authorization changes are the security-relevant event, that is the wrong granularity.
- **DUA draft read and write produce no event at all** (§8.2).
- **AMQP-originated events are attributed to a fabricated user.** `SecurityContextUtil.initAuthenticationContext(String role)` defaults `userId` to `92233720L` (`ms-common/.../SecurityContextUtil.java:51`). Every listener calls this (`RabbitMQStudiesService.java:128, 175, 194, 210, 221, 236, 305, 338, 367`; `StudyUserServiceImpl.java:110`), so any `ShanoirEvent` raised downstream — e.g. the subscription event at `RabbitMQStudiesService.java:267` — records user 92233720 rather than the human who triggered it.
- **The security context is never cleared.** `SecurityContextUtil.clearAuthentication()` exists (`:41-43`) but is called nowhere in this module. Listener threads are pooled, so a `ROLE_ADMIN` context set by one message persists on that thread into the next. Three listeners never set a context at all — `getSubjectsForStudy` (`RabbitMQSubjectService.java:70`), `updateSubjectStudy` (`:87`), `existsSubjectName` (`:124`) — and therefore run under whatever was left behind. They currently call services with no `@PreAuthorize`, so this is latent rather than exploitable, but it is exactly the kind of latency that turns into a vulnerability when someone adds an annotation.

### 9.5 Secrets & transport

`application.yml:34-35` and `:74-75` commit the MariaDB and RabbitMQ credentials. CORS is restricted to `front.server.url` with `allowCredentials(true)` (`SecurityConfiguration.java:96-97`), which is correct. CSRF is disabled (`:73`), acceptable for a stateless bearer-token API. `docker-compose.yml:167` still pins `ghcr.io/fli-iam/shanoir-ng/studies:NG_v2.12.0` while the project version is 3.4.0.

### 9.6 GDPR notes

Right-to-erasure works through `delete-user-queue` → `StudyUserServiceImpl.deleteUser` (`:109`), which removes the user's `StudyUser` rows and broadcasts. But: the broadcast precedes the delete (§8.8), so a failure leaves rights revoked platform-wide while the local rows survive; and `DataUserAgreement` rows referencing the departed user are not cleaned up by that handler. Subject deletion (`SubjectServiceImpl.java:120-146`) does cascade properly to `study_examination`, tags, preclinical and datasets.

---

## 10. Performance & scalability

- **`Study.All` cartesian product.** The entity graph fetch-joins nine collections (`Study.java:75-81`) and is applied to the default `findById` (`StudyRepository.java:31`). For a study with 500 subjects, 5 centers, 20 users, 3000 examinations and 10 tags, one `GET /studies/{id}` materialises a result set that is the product of those bags. This is the single largest performance liability in the service.
- **Unbounded list endpoints.** `findAll()` for studies (`StudyServiceImpl.java:552`) and for subjects (`SubjectServiceImpl.java:149-152`) have no pagination. `GET /subjects` loads and DTO-maps the entire subject table on every call. Only `/subjects/filter` is `Pageable` (`SubjectApi.java:86`).
- **N+1 patterns.**
  - `setFilePaths` (`StudyServiceImpl.java:620-625`): two queries per study, executed for every study returned by `findAll()`.
  - `findStudyUsersByStudyId` (`StudyUserServiceImpl.java:101`): one center query per member, all returning the same rows.
  - `getRights` (`StudyUserServiceImpl.java:78`): `studyUser.getStudyId()` triggers a lazy `Study` load per row.
  - `hasRightOnSubjects` (`StudySecurityService.java:289-291`): one `findByStudy_Id` per study inside a loop.
  - `loadSubjectStudyTags` (`SubjectServiceImpl.java:567-582`): two queries per subject-study, called from `findByPreclinical` for every subject.
  - `filter*` helpers (`StudySecurityService.java:415, 441, 467`): `findAllById` then `hasRightOnTrustedSubjectForOneStudy` per subject, each of which does another `studyRepository.findById` (`:372`). Ironically this expensive work is then discarded (§8.1).
- **Rights checks always hit the database.** Every `@PreAuthorize` invocation re-reads the study and its `studyUserList`; there is no caching layer (`@Cacheable`, Caffeine, or otherwise). On a page that renders 50 studies this is 50+ redundant reads of the same rows within one request.
- **Synchronous RPC inside write transactions** — see §6.2. Worst case a 60-second lock hold.
- **`convertSendAndReceive` used purely for its side effect.** `updateSubjectInMicroservices` (`SubjectServiceImpl.java:445`) and `updateSubjectBatchInMicroservices` (`:462`) discard the reply, paying full round-trip latency for a fire-and-forget notification.
- **Event fan-out cost.** Each study-user mutation publishes one message to a fanout with three bound queues; each consumer independently re-reads and rewrites its local replica. That is cheap. The expensive part is `updateStudyName` (`:895`), which ships the **entire detailed `StudyDTO`** synchronously to `datasets` on every study update just to sync a name.
- **`getAllFiles`** (`StudyApiController.java:657-680`) calls `existsStudyData` once per file across all studies — for an S3 backend that is one HEAD request per file, serially.

---

## 11. Technical debt inventory

Ranked by risk × cost. Effort estimates are for one developer familiar with the codebase.

| # | Item | Effort |
|---|---|---|
| 1 | Broken `filter*` authorization helpers (§8.1) — fix, then push scoping into SQL | 1 day fix / 3 days done properly |
| 2 | Unauthenticated `/dua` endpoints (§8.2) | 0.5 day |
| 3 | `study`-vs-`subjectStudyList` precedence inversion (§8.3, §8.6) and the wider `subjectStudyList` legacy migration (4 `@todo`s) | 1 week |
| 4 | `hasRightOnSubjects` semantics (§8.4) + `hasRightOnCopy` | 0.5 day |
| 5 | Rights-broadcast reliability: afterCommit + publisher confirms + outbox + reconciliation (§8.8) | 1–2 weeks |
| 6 | No DLQ / retry / poison-message handling on ~20 listeners (§8.16) | 3 days |
| 7 | Missing study-level guards on `studyUser`, `dua-download`, `/common`, `/bids`, `/statistics` (§8.9–8.11) | 1 day |
| 8 | `Study.All` entity-graph cartesian product (§10) | 3 days |
| 9 | Transaction-boundary cleanup: inert `@Transactional`, `create()` untransactional, JTA/Spring mix (§6.1) | 2–3 days |
| 10 | Zero tests for dua / messaging / RelatedDataset / RabbitMQStudiesService / StudyUserServiceImpl (§7.2) | 1–2 weeks |
| 11 | Blocking AMQP RPC inside DB transactions (§6.2) | 3 days |
| 12 | No pagination on studies/subjects list endpoints (§10) | 1 week incl. front-end |
| 13 | Rights-check caching (§10) | 3 days |
| 14 | Secrets in `application.yml` (§9.5) | 0.5 day |
| 15 | `SecurityContextUtil` fake user id + never-cleared thread context (§9.4) | 1 day |
| 16 | Duplicated HATEOAS / `Identifiable` / `CenterDTO` / exception classes vs `ms-common` (§4.5) | 2 days |
| 17 | `increment` id generator blocks horizontal scaling (§3.3) | 1 day + migration |
| 18 | Test-code defects: string-vs-Long assertions, zero-assertion test, stubbing a real object (§7.3) | 0.5 day |
| 19 | Dead code: `getUserDir`, `findBy`, `challenge`, stale nginx config, Joda-Time (§6.5) | 1 day |
| 20 | `findIdsAndNamesForCenter` wrong-table bug (§8.19) | 15 min |

---

## 12. Improvement roadmap

### Quick wins (< 1 day each)

1. Fix the five `filter*` helpers to mutate in place (`retainAll`) — §8.1. **Do this first.**
2. Remove `/dua/**` from the `permitAll` matcher and add guards to `PUT`/`GET /dua/{id}` — §8.2.
3. Add `hasRightOnStudy(#studyId, 'CAN_ADMINISTRATE')` to `GET /studies/studyUser/{studyId}` and `CAN_DOWNLOAD` to `dua-download` — §8.9, §8.10.
4. Make `hasRightOnSubjects` all-of and fail-closed on empty — §8.4.
5. Delete `subjectOld.setStudy(subjectNew.getStudy())` at `SubjectServiceImpl.java:401` — §8.6.
6. Replace `!=` with `.equals()` in `studyUsersMatchStudy` and validate against the path variable — §8.13.
7. Fix `findIdsAndNamesForCenter` — §8.19.
8. Return a non-2xx from `uploadDataUseAgreement` on failure — §8.12.
9. Fix `su.getId().equals("1L")` and the zero-assertion test — §7.3.
10. Add `su.confirmed = true` to `findByUserIdAndStudyUserRight` — §8.18.
11. Move DB and RabbitMQ credentials to environment variables — §9.5.
12. Parenthesise the preclinical filter condition — §8.15.

### Medium (1–2 weeks)

1. **Rights-propagation reliability.** `afterCommit` publication, publisher confirms, stop swallowing `MicroServiceCommunicationException`, add a `study_user_outbox` table with a scheduled drainer, and an admin-only "replay all study-users" endpoint.
2. **Dead-letter infrastructure.** One DLX plus per-queue `x-dead-letter-exchange`, a bounded retry policy on the two container factories, and a monitored DLQ.
3. **A dedicated `StudySecurityServiceTest`** covering every public method with both allow and deny cases, and using ids above 127 so boxing bugs surface.
4. **Transaction hygiene.** Make the four private `@Transactional` methods package-private and route them through a self-injected proxy or extract them into collaborators; add `@Transactional` to `StudyServiceImpl.create` and `removeUserFromStudy`; standardise on `org.springframework.transaction.annotation.Transactional`.
5. **Get AMQP RPC out of transactions.** Publish name/subject sync events after commit rather than round-tripping inside the write.
6. **Pagination** on `/studies` and `/subjects`, with rights pushed into the `WHERE` clause.
7. **Reduce `Study.All`.** Split into a light graph for lists and a detail graph, and load the large bags with separate `@BatchSize`d queries.

### Large (architectural)

1. **Make rights a first-class, versioned, verifiable contract.** Today the wire format is "whatever Jackson makes of `StudyUserInterface`", propagated best-effort. Give `StudyUserCommand` an explicit schema and a monotonically increasing version per `study_user` row so consumers can detect gaps and request a resync. This is the single change that would move the platform from "hope the message arrived" to "know the replica is current".
2. **Collapse the double authorization layer.** Pick either the API interface or the service interface as the enforcement point, and make the other advisory. The current split is where §8.3 and §8.5 hide.
3. **Finish the `subjectStudyList` → `subject.study` migration.** Four `@todo`s across `StudySecurityService.java:241, 319, 353` and `RabbitMQSubjectService.java:169` mark a half-completed model change that is directly responsible for two of the three critical findings. Complete it and delete the legacy branches.
4. **Extract a shared `shanoir-ng-authz` library** so that this service, `study-rights` and the three replicas evaluate rights with literally the same code rather than three re-implementations.
5. **Split the module.** `studies` currently owns organisational data (studies/rights), clinical data (subjects), and reference data (centers/equipment/coils/manufacturers). The reference-data half has different scaling, security and change-rate characteristics and would be a clean extraction.

---

## 13. Future work & feature directions

- **Center-scoped rights are stored but never enforced** (§5.2). Either implement enforcement in `hasPrivilege` — which would make `study_user_center` meaningful and is likely what multi-center studies such as OFSEP expect — or remove the table. The current half-state is worse than either.
- **Rights delegation and expiry.** `StudyUser` has no validity window. Time-boxed access for visiting researchers is a natural fit for a data-sharing platform under GDPR and would let DUA re-signature drive re-authorization automatically.
- **Reconciliation and observability for the rights replicas.** A periodic checksum comparison between the source table and the three replicas, surfaced as a health indicator, would turn today's silent drift into an alert.
- **Study templates.** `create()` already does substantial scaffolding (study-users, DUA, tags, centers); a template mechanism would remove a large amount of front-end orchestration.
- **A real DUA e-signature workflow.** The current model is a boolean `confirmed` plus a timestamp. Versioned agreement text, per-version acceptance records, and re-consent on amendment are what a clinical-research audit will ask for.
- **Move statistics out of a stored procedure.** `getStudyStatistics` (`StudyRepositoryImpl.java:42`) hard-codes a 15-column positional mapping (`:62-76`) against a procedure defined in `database-migrations`. Any column change breaks silently at runtime.

---

## 14. Appendix

### 14.1 Largest files (main sources)

| LOC | File |
|---|---|
| 1059 | `study/service/StudyServiceImpl.java` |
| 682 | `study/controler/StudyApiController.java` |
| 639 | `study/security/StudySecurityService.java` |
| 618 | `subject/service/SubjectServiceImpl.java` |
| 598 | `study/model/Study.java` |
| 525 | `study/dto/StudyDTO.java` |
| 445 | `study/controler/StudyApi.java` |
| 397 | `configuration/amqp/RabbitMQStudiesService.java` |
| 316 | `subject/model/Subject.java` |
| 299 | `subject/model/PseudonymusHashValues.java` |
| 278 | `study/service/RelatedDatasetServiceImpl.java` |
| 269 | `subject/dto/SubjectDTO.java` |
| 265 | `study/dto/StudyLightDTO.java` |
| 256 | `center/service/CenterServiceImpl.java` |
| 249 | `subject/controler/SubjectApiController.java` |

### 14.2 Complexity hotspots

| Method | Location | Why |
|---|---|---|
| `StudyServiceImpl.update` | `:311-445` | 134 lines; 10 nested conditionals; mutates tags, study-tags, centers, subjects, files, users; 4 `save` calls; a blocking RPC; throws from the middle |
| `StudyServiceImpl.updateStudyUsers` | `:627-752` | 125 lines; three-way DUA state machine (`addNewDua`/`deleteDua`/`updateDua`) × create/update/delete set arithmetic |
| `StudyServiceImpl.create` | `:181-280` | 99 lines; three-phase save to work around `SubjectStudyTag` ordering; untransactional |
| `StudySecurityService` | whole file | 20 public methods over one 14-line predicate, with five distinct naming conventions (`hasRightOn*`, `hasAnyRight*`, `hasRightOnTrusted*`, `filter*`, `studyUsers*`) |
| `SubjectServiceImpl.mapSubjectStudyListToSubject` | `:278-331` | 53 lines reconciling two competing data models |
| `RabbitMQStudiesService` | whole file | 11 listeners in one class, three of them with inert `@Transactional` |

### 14.3 Full TODO / FIXME / XXX / HACK inventory

Only four markers exist in the entire module, all the same one:

| Location | Text |
|---|---|
| `study/security/StudySecurityService.java:241` | `// @todo: remove later usage of subject study list` |
| `study/security/StudySecurityService.java:319` | `// @todo: remove later usage of subject study list` |
| `study/security/StudySecurityService.java:353` | `// @todo: remove later usage of subject study list` |
| `configuration/amqp/RabbitMQSubjectService.java:169` | `// @todo: to be removed later` |

No `FIXME`, `XXX`, `HACK`, or `@Deprecated` anywhere. The low marker count is not a sign of health — it reflects an unfinished model migration that was never tracked in code, and it is the root cause of §8.3 and §8.6.

Two other stale-comment defects worth listing here because they actively mislead:
- `SubjectApi.java:174` — `// PostAuthorize removed here` sits directly under the `@PostAuthorize` at `:173`.
- `SubjectServiceImpl.java:389` — `// We can not update the study` sits twelve lines above the code that updates the study (`:401`).
- `SubjectServiceImpl.java:488-490` — three lines of commented-out code with the note "after testing this seems to be useless".

### 14.4 Dependency observations

`shanoir-ng-studies/pom.xml` declares only three direct dependencies: `shanoir-ng-ms-common`, `shanoir-ng-storage`, and `jackson-dataformat-csv`. Everything else is inherited from `shanoir-ng-back` → `spring-boot-starter-parent`.

- **Joda-Time** is used in `BIDSServiceImpl.java:24-26` in a class that already imports `java.time.LocalDate`. It arrives transitively; there is no reason for it to be on the classpath.
- **`jackson-dataformat-csv`** is declared but I found no CSV usage in this module — `BIDSServiceImpl` builds TSV with manual `StringBuilder` concatenation (`:123-143`) rather than using it.
- **H2** is used for tests with `MODE=MySQL` (`application.yml:188`) while production is MariaDB with `ddl-auto: validate`. The `@DataJpaTest` repository tests therefore validate against a generated H2 schema, not the real migrated MariaDB schema — divergence between the two is undetectable by the current suite.
- **`allow-circular-references: true`** appears in all three Spring profiles (`:54, 155, 186`), meaning the cycle is real and permanent, not a test-only accommodation.

### 14.5 Checkstyle notes

`shanoir-ng-back/checkstyle.xml` with suppressions at `shanoir-ng-back/suppressions.xml`. Five suppressions, none specific to this module:

```xml
  <suppress checks="MethodName" files=".*Repository\.java"/>
  <suppress checks="Header" files="org/shanoir/ng/importer/eeg/edf/.*\.java"/>
  <suppress checks="Header" files="org/shanoir/ng/importer/eeg/brainvision/.*\.java"/>
  <suppress checks="FinalClass" files=".*Application\.java"/>
  <suppress checks="HideUtilityClassConstructor" files=".*Application\.java"/>
```

The `MethodName` suppression on `*Repository.java` is what permits the Spring Data derived-query name `findByStudyUserList_UserIdAndStudyUserList_StudyUserRightsAndStudyUserList_Confirmed_OrderByNameAsc` (`StudyRepository.java:59`) — which, note, is no longer a derived query at all: it carries an explicit `@Query` (`:51-57`) whose semantics (`JOIN FETCH`, right in `elements(...)`) do not match what the method name claims. Renaming it to something honest is a free readability win.

Checkstyle in CI (`.github/workflows/checkstyle.yml`) enforces style only; none of the defects in §8 are the kind a style checker detects. A SpotBugs or Error Prone pass would have caught the reference-comparison on boxed `Long` (§8.13), the ignored parameter assignment (§8.1), the operator precedence ambiguity (§8.15) and the `Long`/`String` equality in tests (§7.3) — four findings for one build-config change. That is the highest-leverage tooling improvement available to this module.
