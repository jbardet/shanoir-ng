# `shanoir-ng-datasets` — Engineering Audit

**Scope:** `/shanoir-ng-datasets` at commit `867e53290` (develop line), Shanoir-NG 3.4.0.
**Method:** static read of all 466 main classes / 47 test classes. Every claim below carries a `path:LINE`
citation. Where I infer rather than observe, I say so. No code was modified; no build was run.

---

## 1. Executive summary

### What the service does

`shanoir-ng-datasets` is the data-plane of Shanoir-NG. It owns the imaging domain model
(`Dataset` and its 18 subtypes, `DatasetAcquisition`, `DatasetExpression`, `DatasetFile`,
`Examination`, `DatasetProcessing`), and it is the only service that touches actual pixel data.
Concretely it: creates acquisitions from DICOM/EEG/BIDS import jobs pushed over RabbitMQ, stores
DICOM into dcm4chee-arc via STOW-RS, serves a DICOMWeb facade to the OHIF viewer, streams
zip exports (DICOM and on-the-fly NIfTI), indexes everything into Solr, builds and validates BIDS
trees, applies study cards and quality cards, drives VIP pipeline executions and ingests their
outputs, and answers ~127 REST endpoints plus 15 RabbitMQ listeners.

### Overall health verdict: **poor / at risk**

The service works and is clearly under active development (3353 commits touching it), but it has
accumulated the failure modes typical of a module that grew 3× past its intended scope without a
corresponding investment in boundaries or tests. Three things drive the verdict:

1. **A remotely exploitable SQL injection reachable by any authenticated user** (§7.1), in a
   download endpoint that has no authorization annotation at all.
2. **Nine REST endpoints with no authorization check**, several of which return or act on
   patient-linked data (§8.1). Authorization is also frequently applied *after* the query in Java
   (`@PostAuthorize` + `filterXxxList`), which is both slow and easy to get wrong.
3. **Test coverage is ~10% of classes and concentrated on the wrong things.** 172 `@Test` methods
   for 466 classes; the download/zip path, Solr indexing, the RabbitMQ listeners, BIDS export and
   all of VIP are effectively untested, and several existing tests cannot fail (§6.4).

### Top findings, ranked

| # | Finding | Severity | Location |
|---|---------|----------|----------|
| 1 | SQL injection via `data_to_extract[].filter[].type` / `.value`, on an endpoint with **no** `@PreAuthorize`; results are echoed back to the caller through ShanoirEvents | **Critical** | `processing/service/ProcessingDownloaderServiceImpl.java:244-286`, `processing/controler/DatasetProcessingApi.java:195` |
| 2 | Authenticated arbitrary file read: BIDS export path check is a `startsWith` prefix test, so `…/study-1/../../../etc/passwd` passes and is zipped back to the caller | **Critical** | `bids/controller/BidsApiController.java:118-163` |
| 3 | 9 endpoints with no authz annotation — incl. `/carmin-data/path/**` (streams full imaging data), `/vip/execution/{id}/stdout|stderr`, `/examinations/subject/{s}/study/{st}`, `/bids/studyId/{id}/…` | **High** | see §8.1 table |
| 4 | Shared hard-coded temp file `/tmp/metadataExtraction.csv` for the DICOM-metadata CSV export — concurrent users overwrite and can download each other's PHI | **High** | `dataset/service/DatasetServiceImpl.java:662` |
| 5 | `@Transactional protected` methods invoked via `this.` in 9 places — the proxy is bypassed, so **no transaction is ever started**. Includes the RabbitMQ subject/center replication listeners the code comment claims to be protecting | **High** | `configuration/RabbitMQDatasetsService.java:206,242,281,292`; `solr/service/SolrServiceImpl.java:225`; `dataset/service/DatasetServiceImpl.java:472` |
| 6 | STOW-RS response parse failure is treated as **success** ("fail-safe"), so a malformed PACS reply causes Shanoir to record DICOM that was never stored | **High** | `dicom/web/service/DICOMWebService.java:526-530` |
| 7 | Guaranteed NPE + infinite redelivery loop on the `reload-bids-queue` listener when the study row is already gone | **High** | `bids/service/BIDSServiceImpl.java:160-164` |
| 8 | Zip-slip in sorted exports: study/subject/exam-comment strings are concatenated into `ZipEntry` names with no sanitisation | **Medium-High** | `dataset/service/DatasetDownloaderServiceImpl.java:226-259` |

Honourable mentions that did not make the top 8 but are real: raw user text passed to Solr as a
filter query (§8.5), a 500 MB per-request in-memory WebClient buffer on PACS downloads (§9.2),
`indexAll()` deleting the whole Solr index before rebuilding it (§9.4), and a lost-wakeup race that
can silently drop VIP monitoring jobs (§7.9).

---

## 2. Purpose & domain responsibilities

### Owned responsibilities

| Domain | Entry points |
|---|---|
| Dataset & acquisition CRUD | `/datasets/**`, `/datasetacquisition/**` |
| Examinations (visits) | `/examinations/**` |
| Import materialisation (DICOM/EEG/BIDS/processed) | `importer-queue-dataset`, `import-eeg-queue`, `importer-bids-dataset-queue`, `POST /datasets/processedDataset` |
| PACS gateway (STOW-RS store, WADO-RS/URI fetch, IOCM reject) | `dicom/web/service/DICOMWebService.java`, `download/WADODownloaderService.java` |
| DICOMWeb facade for OHIF viewer, with UID virtualisation and patient-name substitution | `/dicomweb/**` |
| Download & export (single, massive, per-study/exam/acq, BIDS, processing outputs) | `/datasets/massiveDownload*`, `/bids/exportBIDS/**`, `/datasetProcessing/massiveDownload*` |
| Solr indexing and faceted search | `/solr/**`, `solr/**` |
| BIDS tree generation + external validator round-trip | `/bids/**` |
| Study cards & quality cards (rule engine over DICOM tags) | `/studycards/**`, `/qualitycards/**` |
| VIP pipeline integration (executions, monitoring, templates, output handlers) | `/vip/**`, `/execution-monitoring/**`, `/execution-template/**`, `/carmin-data/path/**` |
| Statistics & CSV/TSV extraction | `/datasets/downloadStatistics`, `/datasets/dicomMetadataExtraction` |
| Tags, dataset properties, scores | `/studytag/**`, `/properties/**`, `score/**` |

### Where it has too many responsibilities

This is one service doing at least five jobs that have nothing in common except that they read the
same tables:

- **A PACS proxy.** `dicom/web/` + `download/` (≈4.4k LOC) is a DICOMWeb translation layer with its
  own HTTP connection pool (`DICOMWebService.java:121-132`), its own UID virtualisation caches, and
  its own scheduled PACS-purge cron (`DICOMWebService.java:650`). Nothing about it needs the JPA
  entity graph beyond examination→UID lookups.
- **A search indexer.** `solr/` (≈3.4k LOC) keeps a denormalised copy of the whole domain in Solr,
  driven by ten hand-written SQL projection queries (`solr/repository/ShanoirMetadataRepositoryCustom.java:33-368`).
  It shares nothing with the rest of the service except the schema it reads.
- **A workflow/orchestration engine.** `vip/` (≈4.6k LOC) polls an external SaaS, tracks execution
  state in an in-memory queue, and imports results. It even keeps Keycloak offline tokens alive
  (`vip/executionTemplate/service/OfflineTokenKeepAlive.java:50`).
- **A batch/ETL runner.** `CreateStatisticsService`, `CsvCopyService`, `DatasetCopyService`,
  `ExaminationsConsistencyChecker` — long-running jobs bolted onto an HTTP service with `@Async` and
  `@Scheduled`, sharing the same 70-connection Hikari pool as user requests.
- **The BIDS exporter.** `bids/` materialises entire studies as NIfTI on a shared volume and shells
  the result out to a validator container.

The concrete cost of this: `ProcessingResourceApiController` has to log Hikari pool statistics on
every VIP data fetch (`vip/processingResource/controller/ProcessingResourceApiController.java:88-101`)
because the team is evidently fighting connection-pool exhaustion caused by exports and batch jobs
competing with interactive traffic. That is a symptom of a missing service boundary, not of a
missing tuning parameter.

---

## 3. Architecture & code structure

### Metrics

- **Main:** 466 `.java` files, 59 966 LOC (plus generated MapStruct impls under `target/`).
- **Test:** 47 `.java` files, 8 740 LOC, 172 `@Test` methods.
- **REST endpoints:** 127 (enumerated in §4a).
- **RabbitMQ listeners:** 15 across 7 classes. **Publish sites:** 18.

### Package tree (classes / LOC, main source only)

```
org.shanoir.ng
├── bids                    14 /  1 799   BIDS tree build, semaphore, validator round-trip
│   ├── controller           2 /    366
│   ├── model                3 /    170
│   └── service              8 /  1 180
├── configuration            5 /    825   RabbitMQDatasetsService (606), Async, SecurityConfiguration
├── dataset                 90 / 11 141   ← largest cluster
│   ├── controler            4 /  1 150
│   ├── dto (+mapper)       18 /  1 311
│   ├── modality            40 /  3 041   18 Dataset subtypes + mappers + enums
│   ├── model               11 /  1 867   Dataset (564), DatasetExpression (368)
│   ├── repository           2 /    257
│   ├── security             1 /  1 209   DatasetSecurityService — single largest file
│   └── service             13 /  2 445
├── datasetacquisition      52 /  5 837
│   └── model/mr            17 /  2 673   MrProtocol (657), MrProtocolMetadata (513)
├── datasetfile              2 /    166
├── dicom                   19 /  3 673   WADOURLHandler, DICOMWeb facade + service + DTOs
├── download                 9 /  1 389   WADODownloaderService (549), JSONUtils, DicomJsonUtils
├── eeg/model                2 /    430
├── examination             25 /  4 201
├── importer                47 /  5 420   DicomImporterService (721), ImporterService (427)
│   └── strategies          19 /  2 532   dataset / acquisition / expression / protocol strategies
├── processing              14 /  2 134   DatasetProcessing model + downloader
├── property                 8 /    444
├── score                    4 /    432   Score/CodedScore/NumericalScore/ScaleItem — no controller
├── shared                  31 /  2 128   replicated Study/Subject/Center/AcquisitionEquipment
├── solr                    13 /  3 361
├── studycard               50 /  5 185   rule engine: conditions / fields / assignments / rules
├── tag                      9 /    602
├── utils                    1 /    335   DatasetFileUtils
└── vip                     52 /  4 617   execution, monitoring, templates, output handlers, resources
```

### Layering

The nominal layering is `Api` (interface holding the Spring MVC + security annotations) →
`ApiController` (implementation) → `Service`/`ServiceImpl` → `Repository`, with MapStruct mappers
between entity and DTO. It is violated in several places:

- **Controllers that are RabbitMQ listeners.** `DatasetAcquisitionApiController.java:133,147` hosts
  two `@RabbitListener` methods. `BIDSServiceImpl.java:160` (a service) hosts another.
- **Controllers that are cron jobs.** `DatasetApiController.java:610,618` runs the daily statistics
  computation from the controller class.
- **Services that reach into HTTP.** `DICOMWebService` builds its own `CloseableHttpClient`;
  `ExecutionServiceImpl` and `PipelineServiceImpl` each build their own `WebClient`
  (`vip/execution/service/ExecutionServiceImpl.java:102`, `vip/pipeline/service/PipelineServiceImpl.java:49`).
  There are three independent HTTP client stacks in the module (HttpClient5, WebFlux WebClient
  ×2 configurations, plus `RestClientException` handling in `WADODownloaderService`).
- **Repository implementations that build SQL by string concatenation.**
  `solr/repository/ShanoirMetadataRepositoryImpl.java:61,105,112`,
  `processing/service/ProcessingDownloaderServiceImpl.java:286` (a *service* running native SQL
  through an injected `EntityManager`, `:67-68`).

### JPA entity model

`Dataset` is `@Inheritance(strategy = InheritanceType.JOINED)` (`dataset/model/Dataset.java:73`)
with 18 declared `@JsonSubTypes` (`:75-93`): Calibration, Ct, Eeg, Meg, Mesh, Mr, Generic,
ParameterQuantification, Pet, Registration, Segmentation, Spect, Statistical, Template, Bids,
Measurement, Xa, Sr. `DatasetAcquisition` uses the same strategy with Mr/Ct/Pet/Xa/Eeg/Bids variants.

Two structural problems:

- **`AbstractEntity` defines no `equals`/`hashCode`** (`shanoir-ng-ms-common/.../shared/core/model/AbstractEntity.java`
  — only `@Id` + getters). Every entity therefore uses identity semantics. The code nonetheless
  puts entities into `HashSet`s and calls `List.removeAll` on them
  (`dataset/security/DatasetSecurityService.java:756,781`, `importer/service/ImporterService.java:250`).
  This happens to work when the objects come from a single persistence context, and silently fails
  when they do not — e.g. after `datasetAcquisitionService.createAll()` returns fresh instances
  (`importer/service/ImporterService.java:162`).
- **`datasetAcquisition` is `FetchType.EAGER`** on `Dataset` (`dataset/model/Dataset.java:110`).
  Every `findAllById` / `findByStudyId` therefore drags the acquisition (and, transitively, whatever
  the acquisition eagerly holds) for every row. See §9.1.

`getFirstRealInput()` (`Dataset.java:442-448`) recurses through `datasetProcessing.getInputDatasets().get(0)`
with no cycle guard and no empty-list guard: `StackOverflowError` on a processing cycle,
`IndexOutOfBoundsException` on a processing with no inputs. It is called from the download hot path
(`DatasetDownloaderServiceImpl.java:223`, `download/WADODownloaderService.java:197`).

The copy constructor `Dataset(Dataset d)` (`:211-241`) dereferences `d.getProcessings()` (`:222`)
and `d.getReferencedDatasetForSuperimpositionChildrenList()` (`:230`) without null checks — both are
plain `LAZY` fields with no defensive getter, unlike `getDatasetExpressions()` (`:274-279`) which
does initialise. It also aliases the `copies` list rather than copying it (`:240`).

### DB schema owned

MariaDB database `datasets` (`src/main/resources/application.yml`, datasource URL). `ddl-auto: validate`
in production; migrations live outside this module in `docker-compose/database-migrations`. Tables
inferred from the native queries in `solr/repository/ShanoirMetadataRepositoryCustom.java:33-379` and
`dataset/repository/DatasetRepository.java`:

`dataset`, `dataset_metadata`, `mr_dataset`, `mr_dataset_metadata`, `pet_dataset`, `ct_dataset`,
`xa_dataset`, `eeg_dataset`, `bids_dataset`, `generic_dataset`, `measurement_dataset`,
`segmentation_dataset`, `dataset_expression`, `dataset_file`, `dataset_acquisition`,
`mr_dataset_acquisition`, `mr_protocol`, `examination`, `dataset_processing`,
`input_of_dataset_processing`, `execution_monitoring`, `processing_resource`, `study_card`,
`quality_card`, `dataset_tag`, `study_tag`, `subject_tag`, `tag`, `overall_statistics`, plus
**replicated read-models owned by other services**: `study`, `subject`, `center`,
`acquisition_equipment`, `study_user` (kept in sync over AMQP — see §4b).

There is also a stored procedure `computeOverallStatistics()` invoked at
`dataset/repository/DatasetRepository.java:174`.

---

## 4. External interfaces

### 4a. REST API

127 mapped endpoints. Full inventory is long; here is the structure plus **every endpoint whose
authorization is missing or unusual**. (The complete list is reproducible with a scan of
`*Api.java`/`*Controller.java` for `@*Mapping` + `@PreAuthorize`/`@PostAuthorize`.)

**Base paths:** `/datasets`, `/datasetacquisition`, `/datasetProcessing`, `/examinations`,
`/dicomweb`, `/dicomweb-json`, `/bids`, `/solr`, `/studycards`, `/qualitycards`, `/studytag`,
`/properties`, `/importstatus`, `/vip/execution`, `/vip/pipeline`, `/execution-monitoring`,
`/execution-template`, `/execution-template-filter`, `/carmin-data/path`.

**Representative, correctly protected endpoints:**

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/datasets/{datasetId}` | `hasRightOnDataset(#datasetId,'CAN_SEE_ALL')` | fetch one dataset + deps |
| DELETE | `/datasets/{datasetId}` | ADMIN or EXPERT+`CAN_ADMINISTRATE` | delete, unindex, reload BIDS |
| GET | `/datasets/download/{datasetId}` | `hasRightOnDataset(…,'CAN_DOWNLOAD')` | single-dataset zip |
| POST | `/datasets/massiveDownload` | `hasRightOnEveryDataset(#datasetIds,'CAN_DOWNLOAD')` | bulk zip (≤500) |
| GET | `/datasets/massiveDownloadByStudy` | `hasRightOnStudy(#studyId,'CAN_DOWNLOAD')` | study zip (≤500) |
| POST | `/datasets/dicomMetadataExtraction` | `hasRightOnEveryDataset(…,'CAN_SEE_ALL')` | CSV of DICOM tags |
| GET | `/datasets/downloadStatistics`, `/datasets/download/event/{eventId}` | `hasRole('ADMIN')` | platform statistics |
| GET | `/dicomweb/studies/{examinationUID}/series/**` | `hasRightOnExamination(#examinationUID, …)` | OHIF viewer |
| GET | `/examinations/{examinationId}` | `@PostAuthorize hasRightOnTrustedExaminationDTO(...)` | one examination |
| POST | `/studycards/apply` | `hasRightOnEveryDatasetAcquisition(...)` | apply study card |
| POST | `/vip/execution/` | `hasRightOnExecutionCandidates(#candidates)` | launch VIP pipeline |
| POST | `/solr/index` | `hasRole('ADMIN')` | full reindex |

**Endpoints with no `@PreAuthorize`/`@PostAuthorize`:** see §8.1 — this is the security finding, so
the table lives there.

**Auth style note.** Roughly 20 endpoints protect themselves with `@PostAuthorize` + a
`filterXxxList(returnObject.getBody(), …)` call that *mutates the returned list in place and always
returns `true`* (`dataset/security/DatasetSecurityService.java:754-783, 832-860, 870-905, 914-935,
988-1000, 1031-1046`). The rows are fetched from the database first and filtered in Java afterwards.
`checkXxxPage` variants instead return `false` and turn the whole response into a 403 if a single
row is not permitted (`:716-745, 944-979`) — so the platform has two incompatible conventions for
the same problem, and which one you get depends on the endpoint.

### 4b. RabbitMQ

**Consumed (15 listeners):**

| Queue / binding | Constant | Payload | Handler |
|---|---|---|---|
| `study-user-queue-dataset` ← fanout `study-user-exchange` | `STUDY_USER_QUEUE_DATASET` | `String` (command array JSON) | `configuration/RabbitMQDatasetsService.java:152` → `RabbitMqStudyUserService` (ms-common) |
| `study-update-queue` | `STUDY_UPDATE_QUEUE` | `Study` JSON | `RabbitMQDatasetsService.java:161` (**replies** with error string) |
| `subject-update-queue` | `SUBJECT_UPDATE_QUEUE` | `Subject` JSON | `RabbitMQDatasetsService.java:186` (replies `boolean`) |
| `subject_batch_update_queue` | `SUBJECT_BATCH_UPDATE_QUEUE` | `SubjectBatchDTO` JSON | `RabbitMQDatasetsService.java:231` (replies `boolean`) |
| `acquisition-equipment-update-queue` | `ACQUISITION_EQUIPMENT_UPDATE_QUEUE` | `IdName` JSON | `RabbitMQDatasetsService.java:268` |
| `center-update-queue` | `CENTER_UPDATE_QUEUE` | `Center` JSON | `RabbitMQDatasetsService.java:274` |
| `center-delete-queue` | `CENTER_DELETE_QUEUE` | `Long` | `RabbitMQDatasetsService.java:286` |
| `delete-subject-queue` | `DELETE_SUBJECT_QUEUE` | `String` (subject id) | `RabbitMQDatasetsService.java:329` |
| `delete-study-queue` ← topic `events-exchange`, key `DELETE_STUDY_EVENT` | `DELETE_STUDY_QUEUE` | `ShanoirEvent` JSON | `RabbitMQDatasetsService.java:373` |
| `study-datasets-detailed-storage-volume` | `STUDY_DATASETS_DETAILED_STORAGE_VOLUME` | `Long` studyId | `RabbitMQDatasetsService.java:407` (**replies** `StudyStorageVolumeDTO` JSON) |
| `study-datasets-total-storage-volume` | `STUDY_DATASETS_TOTAL_STORAGE_VOLUME` | `List<Long>` | `RabbitMQDatasetsService.java:422` (**replies** `Map<Long,StudyStorageVolumeDTO>` JSON) |
| `copy-datasets-to-study-queue` | `COPY_DATASETS_TO_STUDY_QUEUE` | `RelatedDataset` JSON | `RabbitMQDatasetsService.java:449` (`@Async` — see §7.6) |
| `reload-bids-queue` | `RELOAD_BIDS` | `String` studyId | `bids/service/BIDSServiceImpl.java:160` |
| `bids.validated` | `BidsValidationConfiguration.BIDS_VALIDATION_RESULT_QUEUE` | `Message` (validator JSON) | `bids/service/BidsValidationResultListener.java:29` |
| `importer-bids-dataset-queue` | `IMPORTER_BIDS_DATASET_QUEUE` | `Message` (`BidsImportJob` JSON) | `importer/service/BidsImporterService.java:104` |
| `import-eeg-queue` | `IMPORT_EEG_QUEUE` | `Message` (`EegImportJob` JSON) | `datasetacquisition/controler/DatasetAcquisitionApiController.java:133` (**replies** `int`) |
| `importer-queue-dataset` | `IMPORTER_QUEUE_DATASET` | `Message` (`ImportJob` JSON) | `DatasetAcquisitionApiController.java:147` |
| `find-study-card-queue` | `FIND_STUDY_CARD_QUEUE` | `String` | `studycard/service/RabbitMqStudyCardService.java:45` (**replies** `String`) |
| `import-study-card-queue` | `IMPORT_STUDY_CARD_QUEUE` | `String` | `RabbitMqStudyCardService.java:56` (**replies** `Long`) |
| `examination-creation-queue` | `EXAMINATION_CREATION_QUEUE` | `Message` | `examination/service/RabbitMqExaminationService.java:55` (**replies** `Long` exam id) |
| `examination-extra-data-queue` | `EXAMINATION_EXTRA_DATA_QUEUE` | `String` path | `RabbitMqExaminationService.java:74` |

(That is 21 rows for 15 `@RabbitListener` annotations because several annotations carry multiple
`@RabbitHandler` methods / bindings; the queue names are exact.)

**Published:**

| Queue / exchange | Constant | Payload | Site |
|---|---|---|---|
| `events-exchange` (topic, routing key = event type) | `EVENTS_EXCHANGE` | `ShanoirEvent` JSON | every `ShanoirEventService.publishEvent` call — ~40 sites; ms-common `ShanoirEventService.java:60` |
| `reload-bids-queue` | `RELOAD_BIDS` | `Long` studyId | `dataset/controler/DatasetApiController.java:177`, `dataset/service/DatasetServiceImpl.java:287,307`, `datasetacquisition/controler/DatasetAcquisitionApiController.java:245`, `examination/controler/ExaminationApiController.java:217`, `examination/service/ExaminationServiceImpl.java:162,172` — **self-consumed** by `BIDSServiceImpl.java:160` |
| `nifti-conversion-queue` | `NIFTI_CONVERSION_QUEUE` | `"converterId;srcDir[;destDir]"` (RPC) | `dataset/service/DatasetDownloaderServiceImpl.java:316`, `bids/service/BIDSServiceImpl.java:444` |
| `acquisition-equipment-create-queue` | `ACQUISITION_EQUIPMENT_CREATE_QUEUE` | JSON (RPC → `Long`) | `importer/service/DicomImporterService.java:421` |
| `acquisition-equipment-code-queue` | `ACQUISITION_EQUIPMENT_CODE_QUEUE` | `"all"` (RPC → `Map`) | `importer/service/BidsImporterService.java:214` |
| `center-create-queue` | `CENTER_CREATE_QUEUE` | JSON (RPC → `String`) | `importer/service/DicomImporterService.java:478` |
| `subjects-queue-without-datasets` | `SUBJECTS_QUEUE_WITHOUT_DATASETS` | `SubjectDTO` JSON (RPC → `Long`) | `importer/service/DicomImporterService.java:565` |
| `study-participants-tsv` | `STUDY_PARTICIPANTS_TSV` | `Long` studyId (RPC) | `bids/service/BIDSServiceImpl.java:221` |
| `studies-subject-study-study-card-tag` | `STUDIES_SUBJECT_STUDY_STUDY_CARD_TAG` | JSON | `shared/service/SubjectService.java:107` |
| `examination-study-delete-queue` | `EXAMINATION_STUDY_DELETE_QUEUE` | `ShanoirEvent` JSON | `examination/service/ExaminationServiceImpl.java:171` |
| `import-dataset-mail-queue` / `import-dataset-failed-mail-queue` | `IMPORT_DATASET_MAIL_QUEUE`, `IMPORT_DATASET_FAILED_MAIL_QUEUE` | `EmailDTO` JSON | `importer/service/ImporterMailService.java:130` |
| `execution-monitoring-task` | `EXECUTION_MONITORING_TASK` | `Long` monitoringId (RPC → `String`) | `vip/executionMonitoring/service/ExecutionMonitoringResumptionRunner.java:87` |
| `bids.validate` (default exchange) | `BidsValidationConfiguration.BIDS_VALIDATION_REQUEST_QUEUE` | `String` filePath (+ correlationId header) | `bids/service/BidsValidationPublisher.java:39,48` |

**Reliability posture:** the module declares no dead-letter exchange, no `x-dead-letter-routing-key`,
no retry/backoff policy, and no `spring.rabbitmq.listener.simple.retry.*` configuration in
`application.yml`. It relies entirely on throwing `AmqpRejectAndDontRequeueException` to drop poison
messages — which means a failed import or a failed subject replication is **silently discarded**
with only a log line. Listeners that do *not* throw that exception (e.g. `BIDSServiceImpl.java:160`,
which throws a bare NPE) requeue forever. See §7.7.

**Idempotency:** none of the import listeners is idempotent. `IMPORTER_QUEUE_DATASET`
(`DatasetAcquisitionApiController.java:147`) creates acquisitions unconditionally; a redelivery
after a partial failure duplicates them. There is no processed-message ledger.

### 4c. Outbound HTTP to other services / systems

| Target | Protocol | Where |
|---|---|---|
| **dcm4chee-arc** (`http://${SHANOIR_PREFIX}dcm4chee-arc:8081`) — QIDO-RS, WADO-RS, STOW-RS, IOCM reject/delete | Apache HttpClient5, pooled 500/500 | `dicom/web/service/DICOMWebService.java:121-670` |
| **dcm4chee-arc** — WADO-RS/WADO-URI instance + metadata retrieval for exports | WebFlux `WebClient`, 500 MB in-memory buffer, 5 min timeout | `download/WADODownloaderService.java:134-412` |
| **VIP** (`${VIP_URL_SCHEME}://${VIP_URL_HOST}/rest`) — `/executions`, `/executions/{id}`, stdout, stderr | WebFlux `WebClient` | `vip/execution/service/ExecutionServiceImpl.java:102,139,154,169,189,316` |
| **VIP** — `/pipelines`, `/pipelines/{id}/{version}` | WebFlux `WebClient` | `vip/pipeline/service/PipelineServiceImpl.java:49,56,76` |
| **Keycloak** — service-account token, offline token refresh | ms-common `KeycloakServiceAccountUtils` | `vip/executionTemplate/service/OfflineTokenKeepAlive.java:50` |
| **Solr** (`http://${SHANOIR_SOLR_HOST}:8983/solr/shanoir`) | SolrJ 9.4.1 | `solr/solrj/SolrJWrapperImpl.java` |
| **S3 / MinIO** (`${S3_ENDPOINT}`) — when `storage.type=s3` | AWS SDK via `shanoir-ng-storage` | `shanoir-ng-storage/.../S3StorageService.java` |

There are **no outbound REST calls to other Shanoir microservices** — all inter-service
communication is AMQP. (Good; noted for the synthesis.)

**Inbound callers observed:** nginx (browser/Angular front), the OHIF viewer via
`viewer.ohif.url.base` → `/dicomweb/**`, ShanoirUploader (comments at
`examination/controler/ExaminationApiController.java:183` and `dicom/web/service/DICOMWebService.java:329-336`
explicitly say so), VIP (pulls data via `/carmin-data/path/{uuid}`), and the other microservices via
the AMQP RPC queues listed above.

### 4d. Filesystem / S3 / PACS / Solr touchpoints

- `/var/datasets-data` (`storage.file-system.datasets-data`) — dataset files and acquisition/examination
  "extra data", via `shanoir-ng-storage`.
- `/var/bids-data` (`storage.file-system.bids-data`) — **file-system only by design**, BIDS trees.
  Materialised copies of imaging data, never garbage-collected except by explicit
  `deleteBidsFolder` (`bids/service/BIDSServiceImpl.java:167`).
- `/var/vip-data` — VIP staging.
- `/tmp/<keycloakUserId>/…` — per-user scratch for NIfTI conversion, statistics TSVs and BIDS zips
  (`utils/DatasetFileUtils.java:74-82`, `bids/controller/BidsApiController.java:166-174`).
  Only the statistics/CSV TSVs are cron-cleaned (`dataset/service/CsvCopyService.java:64`,
  `dataset/service/CreateStatisticsService.java:213`); the BIDS zip staging directories are not (§7.11).
- `/tmp/metadataExtraction.csv` — **single shared path**, no user prefix (`dataset/service/DatasetServiceImpl.java:662`).
- Java temp files for on-the-fly gzip of `.nii` during export, correctly deleted in `finally`
  (`utils/DatasetFileUtils.java:233-245`).

### 4e. Shared code from `ms-common` / other modules

Compile dependencies (`pom.xml:35-59`): `shanoir-ng-ms-common`, `shanoir-ng-study-rights`,
`shanoir-ng-storage`, `org.shanoir.anonymization:anonymization`.

Shared **entities** replicated into this DB and kept in sync over AMQP:
`org.shanoir.ng.shared.model.{Study, Subject, Center, AcquisitionEquipment, ManufacturerModel,
Manufacturer, EchoTime, …}` under `shared/model` (14 classes, 1 343 LOC) with their repositories in
`shared/repository`.

Shared **infrastructure**: `RabbitMQConfiguration` (all queue names), `ShanoirEvent` /
`ShanoirEventService` / `ShanoirEventType`, `KeycloakUtil`, `SecurityContextUtil`, `MDCFilter`,
`AbstractEntity`, `RestServiceException`/`ErrorModel`, `StudyUserRight`, `UserRights` and
`StudyRightsService` (from `shanoir-ng-study-rights`), `PageImpl`/`FacetPageable` paging helpers,
`ControllerSecurityService`.

**Test artefact shipped in production:** `shanoir-ng-back/pom.xml:117-121` declares
`spring-security-test` with an explicit comment "do not put scope test here: compile errors", and
`ms-common` exports `org.shanoir.ng.utils.usermock.WithMockKeycloakUser`. That annotation is then
used on a **production** RabbitMQ listener (`datasetacquisition/controler/DatasetAcquisitionApiController.java:150`)
where it is a no-op. See §7.5.

---

## 5. Code quality assessment

### 5.1 Transaction boundaries

**Self-invocation defeats `@Transactional` in nine places.** Spring's proxy-based AOP only applies
when a method is called *through the proxy*. Every one of these is called with an implicit `this.`
from inside the same bean:

| Method | Declared | Called from |
|---|---|---|
| `manageSubjectUpdate` | `configuration/RabbitMQDatasetsService.java:206` | `:190` |
| `manageSubjectBatchUpdate` | `:242` | `:235` |
| `saveCenter` | `:281` | `:278` |
| `deleteCenter` | `:292` | `:289` |
| `beginIndexationProcess` | `solr/service/SolrServiceImpl.java:225` | `:117` |
| `updateEvent(…, Exception)` (`REQUIRES_NEW`) | `dataset/service/DatasetServiceImpl.java:472` | `:454, :458, :460` |
| `deletePartitionOfNiftis` | `dataset/service/DatasetTransactionalServiceImpl.java:61` | via injected service — OK |
| `processKilledJob`, `processFinishedJob` | `vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:280,297` | via self-injected `emProxyService` (`:88-89`) — OK |

The first six are broken. The `RabbitMQDatasetsService` ones are the worst, because
`:197-200` documents the intent explicitly: *"to avoid endless loops rabbitmq re-sending the same
message, we separate the `@Transactional` and `@RabbitListener` in two methods"*. Git history shows
commit `ff37fe20c "Fix bad combination of @Transactional and @RabbitListener: endless loop"` — the
fix was applied but the pattern chosen doesn't work. Consequence: `manageSubjectUpdate` saves a
subject, then loops examinations, then deletes BIDS folders, with **each repository call in its own
implicit transaction**; a failure halfway leaves the subject saved and the BIDS folders half-deleted.

The two `ExecutionMonitoringServiceImpl` cases are done correctly (self-injected `@Lazy` proxy) — so
the team knows the pattern; it just isn't applied consistently.

**Non-transactional work that mutates persistent state:**
`DatasetDownloaderServiceImpl.massiveDownload` (`:127`) has no `@Transactional` and walks
`dataset.getDatasetAcquisition().getExamination().getStudy().getName()` (`:227`),
`.getSubject().getName()` (`:231`), `.getComment()` (`:235`) — all lazy traversals. This currently
works only because `spring.jpa.open-in-view` is left at its Spring Boot default of `true`
(it is set to `false` in `shanoir-ng-import`, `-users` and `-studies` but **not** in
`shanoir-ng-datasets/src/main/resources/application.yml`). See §9.3 for why relying on OSIV here is
expensive.

**Side effects inside transactions that can roll back:**
`dataset/service/DatasetServiceImpl.java:181-198` — `deleteById` is `@Transactional` and calls
`deleteDatasetFilesFromDiskAndPacs` (`:194`) which kicks off `@Async` deletion of files from disk and
rejection from the PACS (`:233`). If the surrounding transaction later rolls back (e.g. the
`deleteByIdIn` loop at `:244-248` fails on dataset #7 of 500), the DB rows come back but the
**imaging files are already gone**. Same class of bug at `examination/service/ExaminationServiceImpl.java:158-162`
where `rejectExaminationFromPacs` and the `RELOAD_BIDS` publish happen before/inside the caller's tx.

### 5.2 Swallowed exceptions

Six fully empty or comment-only catch blocks:

```
dataset/service/DatasetServiceImpl.java:596      catch (Exception ignored) {}
dataset/service/DatasetServiceImpl.java:631      catch (Exception ignored) {}
solr/service/SolrServiceImpl.java:141            catch (SolrServerException | IOException ignored) {}
solr/solrj/SolrJWrapperImpl.java:487             catch (RuntimeException ignored) {}
studycard/service/CardsProcessingService.java:113  catch (EntityNotFoundException e) { } // too bad
studycard/service/CardsProcessingService.java:160  catch (EntityNotFoundException e) { } // too bad
vip/executionTemplate/service/PlannedExecutionServiceImpl.java:160  catch (Exception ignored) { }
```

`SolrServiceImpl.java:141` is the most damaging: `indexAllNoAuth()` deletes the entire Solr index
(`:139` → `cleanOldIndex` → `deleteAll`) and then swallows any failure of the *rebuild*, leaving
search permanently empty with no log line.

`DatasetServiceImpl.java:596` and `:631` swallow PACS-metadata retrieval failures during CSV export,
so the exported CSV silently contains blank columns instead of reporting that the PACS was
unreachable — a data-integrity problem for a research export.

Log-and-continue is also pervasive: `LOG.error(…)` followed by `return null` appears at
`dicom/web/service/DICOMWebService.java:150,182,210,267,309,365` for every PACS query. The class
javadoc (`:64-70`) says this is deliberate ("all query methods return null and log an error"), but
the caller at `dicom/web/DICOMWebApiController.java:174-178` then silently drops the examination from
the viewer's study list — the user sees missing data with no indication why.

### 5.3 Thread safety and mutable state

- **`SimpleDateFormat` as a singleton field.** `bids/service/BIDSServiceImpl.java:156` —
  `private SimpleDateFormat formatter` on a `@Service` (singleton), used at `:434` to build temp
  folder names. `SimpleDateFormat` is not thread-safe; concurrent BIDS exports of different studies
  will produce corrupted/duplicate folder names or throw `NumberFormatException` from inside
  `format()`. `DateTimeFormatter` at `:158` is fine; the fix is to use it everywhere.
- **Mutable static counter.** `importer/service/ImporterService.java:69` —
  `private static int instancesCreated`, incremented non-atomically at `:107` in the constructor of a
  `@Scope("prototype")` bean. Benign (it only feeds a log line at `:115`) but it is a data race.
- **In-memory caches cleared only by cron.** `dicom/web/StudyInstanceUIDAndSubjectNameHandler.java:103,105`
  and `dicom/web/SeriesInstanceUIDHandler.java:101,103` are `ConcurrentHashMap`s with no size bound
  and no TTL, flushed once a day at 06:00 (`:115`, `:112`). They cache examination→StudyInstanceUID
  and **examination→subject name** — i.e. they hold PHI in memory for up to 24 h with unbounded
  growth. `importer/service/DicomImporterService.java:197,199` are the same pattern, flushed every
  15 min (`:209`).
- **`BidsValidationAwaiter` leaks futures.** `bids/service/BidsValidationAwaiter.java` puts a
  `CompletableFuture` into `pending` on `register()` and only removes it in `complete()`/`fail()`.
  If the bids-validator container never answers, the entry stays forever. No timeout eviction.

### 5.4 Dead / vestigial code

- `examination/schedule/ExaminationsConsistencyChecker.java` — 337 LOC whose only entry point has its
  `@Scheduled` **commented out** (`:96`).
- `dicom/web/DICOMWebApiController.java:110,193,404,422,428,441` — six mapped endpoints that
  `return null` unconditionally. They are still exposed and still consume a URL namespace;
  `stow` (`:440`) returns `null` for a `POST /dicomweb/studies` that Spring will render as an empty
  200.
- `vip/processingResource/controller/ProcessingResourceApiController.java:59` — `// TODO implement
  those actions`, four action verbs return 501.
- `score/` (4 classes, 432 LOC) has no controller, no service and no repository — unreferenced
  domain model.
- `solr/repository/ShanoirMetadataRepositoryCustom.findAllAsSolrDoc()` is declared (`:411`) and
  implemented (`ShanoirMetadataRepositoryImpl.java:53`) but never called from main source.
- `spring-data-solr` 4.3.15 is retained purely for one class (`SolrResultPage`), documented in
  `pom.xml:84-86`. That artifact has been EOL since 2020.

### 5.5 Copy-paste duplication

- **The ten Solr projection queries** (`solr/repository/ShanoirMetadataRepositoryCustom.java:33-368`)
  are 90% identical — same 24-column SELECT, same six LEFT JOINs, differing only in the modality
  table. ~330 lines of duplicated SQL. Adding a column means editing ten strings; the `EEG_QUERY`
  already diverges (`:194` uses `d.origin_metadata_id` where the others use `d.updated_metadata_id`),
  which may or may not be intentional.
- **The two `getStudyIdFromDataset` overloads** (`dataset/security/DatasetSecurityService.java:506-518`
  and `:520-532`) and the two `hasRightOnTrustedDataset` overloads (`:467-481`, `:490-504`) are
  character-for-character identical apart from the parameter type. Same for the six
  `filterXxxDTOList`/`checkXxxPage` variants.
- **DICOM patient-info rewriting** is implemented three times:
  `download/WADODownloaderService.java:455-465` (to file), `:536-547` (to stream),
  `dicom/web/service/DICOMWebService.java:312-326` (to byte[]). Three chances to forget a tag.
- **`getUserImportDir`** exists twice with identical bodies:
  `utils/DatasetFileUtils.java:74-82` and `bids/controller/BidsApiController.java:166-174`.
- **`massiveDownload`'s try/catch/zip skeleton** is duplicated between
  `dataset/service/DatasetDownloaderServiceImpl.java:127-213` and
  `processing/service/ProcessingDownloaderServiceImpl.java:70-103` (the latter extends the former but
  reimplements rather than reuses).

### 5.6 Miscellaneous smells

- `dataset/service/DatasetServiceImpl.java:506` — `LOG.error(objectMapper.writeValueAsString(dataset))`
  serialises an entire JPA entity into the log on an unexpected-state path. This both triggers lazy
  loads outside a known transaction and writes dataset metadata (which can carry subject-identifying
  strings) to `/var/log/shanoir-ng-logs/shanoir-ng-datasets.log`.
- `solr/service/SolrServiceImpl.java:309,331` — `indexationProgess` (sic) is initialised to 0 and
  never incremented, so the reported reindex progress is pinned at 10%.
- `configuration/RabbitMQDatasetsService.java:480` — `Float.valueOf(countProgress / countTotal)` is
  integer division; the initial progress of a copy job is always `0.0`.
- `solr/solrj/SolrJWrapperImpl.java:206` —
  `e.getMessage().substring(e.getMessage().indexOf("shanoir") + 9)` throws
  `StringIndexOutOfBoundsException` when "shanoir" is absent and the message is shorter than 8 chars,
  and otherwise leaks raw Solr internals to the HTTP client.
- `dicom/web/dto/mapper/ExaminationToStudyDTOMapper.java:56-57` — `patientBirthDate` is hard-coded to
  `"01011960"` and `patientSex` to `"F"` for every subject exposed through the DICOMWeb facade.
  Flagged `@TODO` but shipping.
- `configuration/AsyncConfiguration.java:33-35` — core = max = 100 threads, queue 500, on a service
  that also enables virtual threads (`application.yml`, `spring.threads.virtual.enabled: true`).
  A platform-thread pool of 100 sitting behind virtual-thread request handling is at best redundant.
- `spring.main.allow-circular-references: true` is set in all three profiles — the module has
  circular bean dependencies it has chosen to paper over (`DatasetServiceImpl.java:124,146` uses
  `@Lazy` for the same reason).

---

## 6. Test coverage analysis

### 6.1 Numbers

| Metric | Value |
|---|---|
| Main classes | 466 |
| Test classes | 47 (10.1%) |
| `@Test` methods | 172 |
| Test LOC / main LOC | 8 740 / 59 966 = 14.6% |
| `@Disabled` / `@Ignore` | 0 |

By type: **26 `@SpringBootTest`** (full context, H2), **6 `@WebMvcTest`**, **3 `@DataJpaTest`**,
**3 plain Mockito (`@ExtendWith(MockitoExtension)`)**, **4 pure unit** (no Spring),
**1 shared fixture** (`utils/ModelsUtil.java`), **4 `*TestIT`** integration tests. There is no Jacoco
plugin configured in `shanoir-ng-back/pom.xml` and no coverage gate in CI
(`.github/workflows/maven.yml` runs `mvn install -Dcheckstyle.skip=true`), so no coverage number is
tracked at all.

### 6.2 Per-package coverage map

| Package | Main classes | Test classes | Verdict |
|---|---|---|---|
| `dataset/security` | 1 (1209 LOC) | 3 (`DatasetApiSecurityTest`, `DatasetServiceSecurityTest`, …) | **Best-covered area** — the security tests are the strongest asset in the module |
| `studycard` | 50 | 7 | Reasonable on API/security, thin on the rule engine (`model/condition`, `model/rule`, `model/field` = 2 291 LOC, **0 tests**) |
| `examination` | 25 | 7 | Adequate |
| `datasetacquisition` | 52 | 7 | API + mapper + repository covered; the 17 MR-protocol model classes (2 673 LOC) untested |
| `dicom/web` | 19 | 5 | Reasonable for the facade; `STOWRSMultipartRequestFilter` untested |
| `dataset` (service/controller) | 90 | 6 | `DatasetServiceImpl` (685 LOC) has no direct test |
| `importer` | 47 | 4 | `DicomImporterService` (721 LOC) has 2 tests; `strategies/**` (2 532 LOC) has 1 |
| `bids` | 14 | 3 | `BIDSServiceImpl` (855 LOC) has 1 test method |
| **`solr`** | **13 (3 361 LOC)** | **0** | **Zero coverage** |
| **`download`** | **9 (1 389 LOC)** | **0** | **Zero coverage** (`DatasetDownloaderServiceTest` covers the *service*, not `WADODownloaderService`) |
| **`configuration`** (RabbitMQ listeners) | **5 (825 LOC)** | **0** | **Zero coverage** |
| **`vip`** | **52 (4 617 LOC)** | **1** (`ExecutionApiControllerTest`, 4 tests) | Effectively zero |
| **`processing`** | **14 (2 134 LOC)** | **2** (output handlers only) | `ProcessingDownloaderServiceImpl` — the SQLi site — **untested** |
| **`property`, `tag`, `score`, `datasetfile`, `shared`** | 54 | 0 | **Zero coverage** |

### 6.3 What is tested well

`DatasetApiSecurityTest` (544 LOC), `DatasetServiceSecurityTest` (500),
`DatasetAcquisitionApiSecurityTest` (423), `ExaminationApiSecurityTest` (372) and their peers are
genuinely good: they enumerate role × right combinations and assert `AccessDeniedException` is or
isn't thrown. This is the right shape of test for this domain and it is why the *annotated*
endpoints are mostly correct. The gap is that these tests can only test endpoints someone remembered
to write a test for — they cannot detect a **missing** `@PreAuthorize` (see §8.1).

### 6.4 Test quality problems

**Tests that cannot fail.** `dataset/DatasetDownloaderServiceTest.java:181-187`:

```java
try {
    this.datasetDownloaderService.massiveDownload("otherWRONG", …);
} catch (RestServiceException e) {
    assertEquals("Unexpected error while downloading dataset files", e.getErrorModel().getMessage());
}
// THEN we expect a failure
```

If no exception is thrown — i.e. if the bug this test guards against is reintroduced — the test
**passes**. There is no `fail()` after the call. This idiom should be `assertThrows`.

**Tests that assert on the event, not the output.** The other two tests in the same file
(`:190-273`) drive a full zip export and then assert only on `response.getContentType()` and the
fields of the published `ShanoirEvent`. Nothing verifies that the zip contains the expected entries,
that the entry names are correct, or that the bytes match. A zip-slip regression or a truncated
stream would pass.

**Over-mocking.** `DatasetDownloaderServiceTest` declares 13 `@MockBean`s around a single class under
test. `ExaminationApiControllerTest` and friends mock the service layer entirely, so the
`@WebMvcTest`s verify only Spring MVC wiring and JSON shape.

**Assertion density.** Twelve test classes have a single `@Test` method
(`BidsServiceTest`, `DatasetFileUtilsTest`, `DicomImporterServiceTest` has 2, `DefaultHandlerTest`,
`ImporterServiceTest`, `EegImporterServiceTest`, `ShanoirEventServiceTest`, `StudyUserProcessCommandTest`,
`BidsDeserializerTest`, `ExaminationToStudyDTOMapperTest`, `DICOMJsonApiControllerTest`). For a
855-LOC class like `BIDSServiceImpl`, one test method is a smoke test, not coverage.

**No negative-path tests.** I found no test that exercises: a PACS returning 500, a Solr connection
failure, a RabbitMQ redelivery, a `nifti-conversion-queue` RPC timeout (which currently NPEs — §7.10),
a partially-failed massive download, or a concurrent access to any shared temp file.

### 6.5 Highest-value missing tests, prioritised

1. **`ProcessingDownloaderServiceImpl.getDatasetIdsFromJsonFilters` — injection tests.** Feed
   `{"type": "1) UNION SELECT id FROM subject --"}` and `{"value": "' OR '1'='1"}` and assert
   rejection. This is the Critical finding and it has zero tests today.
2. **`BidsApiController.exportBIDSFile` — path-traversal tests.** `filePath=/var/bids-data/study-1/../../etc/passwd`
   and `filePath=/var/bids-data/study-10` while authorised only on study 1. Both must 403.
3. **An authorization-completeness meta-test.** Reflectively enumerate every `@*Mapping` method in
   every `*Api` interface and assert it carries `@PreAuthorize` or `@PostAuthorize`, with an explicit
   allow-list. This one test would have caught all nine gaps in §8.1 and prevents regressions
   permanently. Highest value-per-line in the whole list.
4. **`DatasetDownloaderServiceImpl.massiveDownload` — zip content tests.** Assert entry names for
   `sorting != null` (zip-slip), assert `failures.txt`/`ERRORS.json` presence, assert the temp NIfTI
   directory is deleted, assert behaviour when `getDatasetExpressions()` is empty (currently
   `IndexOutOfBoundsException` at `:274`).
5. **RabbitMQ listener tests** for `RabbitMQDatasetsService` — in particular that
   `manageSubjectUpdate` is actually transactional (a test that forces a failure after
   `subjectRepository.save` and asserts rollback would fail today).
6. **`DICOMWebService.parseJsonResponse`** — assert that an unparseable STOW-RS response is treated
   as a **failure**, not a success (`:526-530`).
7. **`SolrServiceImpl.indexAll`** — assert the index is not emptied before the rebuild succeeds, and
   that `indexAllNoAuth` surfaces failures.
8. **`BIDSServiceImpl.deleteBidsForStudy`** with a non-existent study id — must not NPE.
9. **`BidsTreeSemaphore`** — concurrency test proving that a failure between `lockOrThrow` and the
   `try` block does not deadlock the study, and that `unlock()` without `lock()` does not inflate the
   permit count.
10. **`DatasetServiceImpl.findPage`** with center restrictions and a page number beyond the filtered
    result — currently throws from `subList` (`:377`).

---

## 7. Bugs & correctness risks

### Ranked summary

| # | Severity | Finding | Location |
|---|---|---|---|
| 7.1 | **Critical** | SQL injection in `complexMassiveDownload` filter parsing, unauthenticated by annotation | `processing/service/ProcessingDownloaderServiceImpl.java:244-286` |
| 7.2 | **Critical** | Path traversal / arbitrary file read in BIDS export | `bids/controller/BidsApiController.java:118` |
| 7.3 | **High** | Shared `/tmp/metadataExtraction.csv` — cross-user PHI leak + corruption | `dataset/service/DatasetServiceImpl.java:662` |
| 7.4 | **High** | `@Transactional protected` self-invocation — no transaction (6 sites) | see §5.1 |
| 7.5 | **High** | Test annotation `@WithMockKeycloakUser` on a production RabbitMQ listener → empty SecurityContext | `datasetacquisition/controler/DatasetAcquisitionApiController.java:150` |
| 7.6 | **High** | `@Async` on a `@RabbitListener` → message ACKed before work runs, `AmqpRejectAndDontRequeueException` unreachable | `configuration/RabbitMQDatasetsService.java:449-452,577` |
| 7.7 | **High** | Guaranteed NPE + infinite requeue on `reload-bids-queue` | `bids/service/BIDSServiceImpl.java:160-164` |
| 7.8 | **High** | STOW-RS parse failure counted as success → phantom PACS records | `dicom/web/service/DICOMWebService.java:526-530` |
| 7.9 | **High** | Lost-wakeup race silently drops VIP monitoring jobs | `vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:135-143,216` |
| 7.10 | **Medium** | NPE in `finally` masks the real exception; NPE on null converter result | `dataset/service/DatasetDownloaderServiceImpl.java:290,330` |
| 7.11 | **Medium** | BIDS zip staging directories never deleted → unbounded disk growth | `bids/controller/BidsApiController.java:135-163` |
| 7.12 | **Medium** | Zip-slip via unsanitised study/subject/exam names in sorted exports | `dataset/service/DatasetDownloaderServiceImpl.java:226-259` |
| 7.13 | **Medium** | `IndexOutOfBoundsException` on paged, center-restricted dataset listing | `dataset/service/DatasetServiceImpl.java:377` |
| 7.14 | **Medium** | BIDS semaphore permanently deadlocks a study if the study row is missing | `bids/service/BIDSServiceImpl.java:188-192` |
| 7.15 | **Medium** | `IndexOutOfBoundsException`/`StackOverflowError` in `getFirstRealInput` | `dataset/model/Dataset.java:442-448` |
| 7.16 | **Medium** | `Integer.valueOf(null)` / `Long.valueOf(garbage)` → 500 on DICOMWeb study search | `dicom/web/DICOMWebApiController.java:117-118,140-141` |
| 7.17 | **Low** | Progress reporting broken (integer division, unincremented counter) | `RabbitMQDatasetsService.java:480`, `SolrServiceImpl.java:309` |
| 7.18 | **Low** | Duplicate DICOM instance treated as a hard error on re-send | `dicom/web/service/DICOMWebService.java:474` |

---

### 7.1 (Critical) SQL injection in `complexMassiveDownload`

**Location:** `processing/service/ProcessingDownloaderServiceImpl.java:234-309`;
entry point `processing/controler/DatasetProcessingApi.java:195` +
`processing/controler/DatasetProcessingApiController.java:242`.

**What's wrong.** The endpoint accepts a free-form `JsonNode` body and builds a native SQL string by
concatenation:

```java
// :257  — `type` comes straight from the request body
String queryFilter = correctFilterType(jsonFilter.get("type").asText());
...
// :266  — date branch: raw value, no quoting at all
if (queryFilter.endsWith("date")) { filter += " " + valueStr + " "; }
// :270  — string branch: single-quoted with no escaping of `'`
else { filter += " REGEXP '" + valueStr.replaceAll(",", "|") + "'"; }
...
// :276/:279-282  — assembled into the WHERE clause
queryFilters.get(queryFilter).add(queryFilter + filter);
query += queryFilters.values().stream().map(l -> "(" + String.join(" OR ", l) + ")")
                     .collect(Collectors.joining(" AND ")) + ";";
// :286
idList = em.createNativeQuery(query).getResultList();
```

`correctFilterType` (`:312-320`) only rewrites two known table prefixes and returns the input
unchanged in its `default` branch, so `type` is a raw injection point. `value` is a second injection
point via both the date branch (`:266`, entirely unquoted) and the REGEXP branch (`:270`, no quote
escaping).

**Why it is worse than a normal blind SQLi.** `complexMassiveDownload` doesn't actually stream a zip
— it publishes the resulting id list back to the user in a `ShanoirEvent` message
(`:129`: `partition.stream().map(String::valueOf).collect(Collectors.joining(","))`). A
`UNION SELECT`-based payload therefore has its results **echoed straight back to the attacker**
through the events channel. No blind extraction needed.

**Reachability.** `POST /datasetProcessing/complexMassiveDownload` carries **no `@PreAuthorize`**
(`DatasetProcessingApi.java:195` — verified: no security annotation anywhere in the block), so any
principal with a valid Shanoir JWT (role `USER` suffices) can call it. There is no study-rights check
anywhere in the flow.

**Impact.** Full read of the `datasets` MariaDB schema: subject names, examination comments and
dates, study membership, dataset file paths, `study_user` rights rows. Depending on the DB grant of
the `datasets` user, `LOAD_FILE()` and write primitives may also be available. Stacked statements are
normally blocked by the MariaDB connector's default `allowMultiQueries=false`, which is the only
thing standing between this and arbitrary DML.

**Fix.** (a) Add `@PreAuthorize` and per-study rights filtering to the endpoint immediately as a
stop-gap. (b) Replace the string builder with a fixed allow-list mapping `type` → a whitelisted
`table.column` pair, and bind every value with `Query.setParameter`. (c) Better: express the filter
model as a typed DTO with an enum of permitted fields rather than a raw `JsonNode`, and use the JPA
Criteria API. (d) Add the injection tests from §6.5.1.

### 7.2 (Critical) Path traversal in `exportBIDSFile`

**Location:** `bids/controller/BidsApiController.java:112-164`.

```java
// :118
if (!filePath.startsWith(bidsStorageDir + "/study-" + studyId)) {
    response.sendError(HttpStatus.UNAUTHORIZED.value()); return;
}
// :124
File fileToBeZipped = new File(filePath);
```

**Two distinct problems in one line.**

1. **Traversal.** `startsWith` is a string prefix test on an unnormalised path.
   `/var/bids-data/study-1/../../../etc/passwd` satisfies it. The file is then copied
   (`:141-145`), zipped (`:150`) and streamed back to the caller (`:155-160`). The caller needs
   `CAN_DOWNLOAD` on *some* study (the `@PreAuthorize` at `bids/controller/BidsApi.java:74` checks
   `#studyId`) and then reads any file the JVM can read — including
   `/var/datasets-data/**` (all other studies' imaging data) and any mounted secret.
2. **Prefix collision.** `study-1` is a prefix of `study-10`, `study-11`, `study-100`. A user
   authorised on study 1 can pass `filePath=/var/bids-data/study-10` and export study 10's entire
   BIDS tree.

`validateBidsByStudyId` (`:210`) has the same class of check but weaker still — it only requires the
path to start with `bidsStorageDir`, so *any* study's tree can be pushed through the external
validator.

**Fix.** Resolve and normalise, then verify containment:
`Path base = Paths.get(bidsStorageDir, "study-" + studyId).toRealPath();
Path target = Paths.get(filePath).toRealPath(); if (!target.startsWith(base)) reject;`
`Path.startsWith` is segment-aware, so it also fixes the `study-1`/`study-10` collision. Better
still: stop accepting absolute paths from the client at all and take a relative path inside the
study's own tree.

### 7.3 (High) Shared temp file for DICOM metadata extraction

**Location:** `dataset/service/DatasetServiceImpl.java:661-684`, reached from
`POST /datasets/dicomMetadataExtraction`.

```java
// :662
File metadataFile = new File("/tmp/metadataExtraction.csv");
```

A single hard-coded path with no user or request discriminator. Concurrent extractions by different
users write to the same file: `createMetadataFile` deletes and recreates it (`:664-667`) while
another request's `fillMetadataFile` (`:609`, opened in append mode) is still writing. The controller
then streams whatever is on disk back to the requester
(`dataset/controler/DatasetApiController.java:639-659`). **User A can receive user B's DICOM metadata
for datasets A has no rights on.** The file is never deleted, so the last extraction's PHI sits in
`/tmp` indefinitely.

Two secondary issues in the same code path: the CSV is built by naive `+=` concatenation with `;`
separators and **no escaping** (`:635-638`), so a metadata value containing `;` or a newline corrupts
the file and a value starting with `=`/`+`/`-`/`@` is a spreadsheet formula-injection payload; and
each dataset triggers a separate blocking PACS round-trip (`:653`), so 500 datasets = 500 serial HTTP
calls inside one request thread.

**Fix.** `Files.createTempFile()` per request, delete in a `finally`, use `opencsv` (already a
dependency, `pom.xml:88-92`) for escaping.

### 7.4 (High) Broken `@Transactional` — see §5.1

Fix: inject a self-reference with `@Lazy` (the pattern already used at
`vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:87-89`) or move the transactional
method to a separate `@Service`. Make the methods `public` — Spring's default `proxyTargetClass`
CGLIB proxies can advise `protected` methods but many teams' JDK-proxy configurations cannot, and
`protected` gives a false sense that the annotation is scoped.

### 7.5 (High) Test annotation on a production listener

**Location:** `datasetacquisition/controler/DatasetAcquisitionApiController.java:147-151`.

```java
@RabbitListener(queues = RabbitMQConfiguration.IMPORTER_QUEUE_DATASET, …)
@RabbitHandler
@Transactional
@WithMockKeycloakUser(authorities = { "ROLE_ADMIN" })
public void createNewDatasetAcquisition(Message importJobStr) { … }
```

`@WithMockKeycloakUser` is a `@WithSecurityContext` meta-annotation
(`shanoir-ng-ms-common/.../utils/usermock/WithMockKeycloakUser.java:30`). It is processed *only* by
`WithSecurityContextTestExecutionListener`, which exists solely inside a JUnit/Spring test run.
**At runtime in production it does nothing.** The main DICOM import listener therefore executes with
an empty `SecurityContext`, unlike its sibling at `:136` which correctly calls
`SecurityContextUtil.initAuthenticationContext("ROLE_ADMIN")`.

Anything downstream that calls `KeycloakUtil.getTokenUserId()` or evaluates a `@PreAuthorize` during
import will misbehave. It happens to survive today because `ImporterService.createAllDatasetAcquisition`
calls `SecurityContextUtil.initAuthenticationContext("ROLE_ADMIN")` itself at
`importer/service/ImporterService.java:120` — but only *after* `eventService.publishEvent(event)`
(`:118`) and `datasetsImportStatusService.markInProgress(...)` (`:119`) have already run.

This is also why `spring-security-test` is a **compile-scope** dependency shipped in the production
jar (`shanoir-ng-back/pom.xml:117-121`, with the comment "do not put scope test here: compile
errors"). Removing this one annotation would let that dependency move back to `test` scope across the
whole backend.

**Fix.** Replace with `SecurityContextUtil.initAuthenticationContext("ROLE_ADMIN")` as the first
statement, then move `spring-security-test` to `<scope>test</scope>`.

### 7.6 (High) `@Async` on a `@RabbitListener`

**Location:** `configuration/RabbitMQDatasetsService.java:449-452`.

```java
@RabbitListener(queues = RabbitMQConfiguration.COPY_DATASETS_TO_STUDY_QUEUE, containerFactory = "multipleConsumersFactory")
@RabbitHandler
@Async
public void copyDatasetsToStudy(final String data) { … }
```

With `@Async`, the listener container's invocation returns immediately and the message is ACKed
before any work is done. The `throw new AmqpRejectAndDontRequeueException(...)` at `:577` executes on
an `AsyncThread-*` pool thread where AMQP has no idea it happened — it becomes an uncaught exception
logged by the executor. Consequences:

- A broker or service restart mid-copy loses the whole job with no redelivery.
- The error path is dead code; the only signal the user gets is the `ShanoirEvent` at `:568-575`.
- Up to 100 concurrent copy jobs can be started (the `asyncExecutor` pool size,
  `configuration/AsyncConfiguration.java:33`), each holding DB connections from the 70-connection
  pool. Copy jobs and interactive requests will deadlock on connection acquisition well before that.

**Fix.** Drop `@Async` and let the listener container's concurrency setting bound parallelism, using
manual ACK after the work completes.

### 7.7 (High) NPE + infinite requeue on `reload-bids-queue`

**Location:** `bids/service/BIDSServiceImpl.java:160-164`.

```java
@RabbitListener(queues = RabbitMQConfiguration.RELOAD_BIDS)
public void deleteBidsForStudy(String studyId) {
    Study studyDeleted = studyRepo.findById(Long.valueOf(studyId)).orElse(null);
    this.deleteBidsFolder(studyDeleted.getId());   // ← NPE when orElse(null)
}
```

The `orElse(null)` is immediately dereferenced. This is not hypothetical: `deleteStudy`
(`configuration/RabbitMQDatasetsService.java:400`) deletes the study row, and
`ExaminationServiceImpl.deleteById` (`:162`) publishes `RELOAD_BIDS` for that same study during the
cascade — so a study deletion reliably races into this path. `Long.valueOf(studyId)` is a second
failure mode for a malformed payload.

Because this listener has **no** `containerFactory` override and does **not** throw
`AmqpRejectAndDontRequeueException`, the default `SimpleRabbitListenerContainerFactory` behaviour
applies: the message is requeued and redelivered immediately, forever. One poison message pins a
consumer thread and floods the log.

**Fix.** `studyRepo.findById(...).ifPresent(s -> deleteBidsFolder(s.getId()));`, wrap the parse, and
configure a DLQ for this queue.

### 7.8 (High) STOW-RS "fail-safe" treats parse errors as success

**Location:** `dicom/web/service/DICOMWebService.java:489-532`.

```java
} catch (Exception e) {
    LOG.error("Error parsing JSON STOW-RS response: {}", e.getMessage(), e);
    // Treat as success if we can't parse (fail-safe)
    result.incrementSuccess();       // :529
}
...
if (result.getInstances().isEmpty()) { result.incrementSuccess(); }   // :523-525
```

The class javadoc (`:64-70`) states the opposite intent: *"For all storage calls, that are important
to arrive an exception is thrown back to the user to avoid silent none storage."* As written, if
dcm4chee returns an HTML error page, a truncated body, or an unexpected JSON shape, `sendMultipartRequest`
returns a "successful" result and `ImporterService.persistSeriesInPacs`
(`importer/service/ImporterService.java:349-360`) reports success. The DB then holds
`dataset_expression`/`dataset_file` rows with WADO URLs pointing at instances that were never stored,
and the failure surfaces months later as a broken download or an empty viewer. In a clinical-research
context that is silent data loss.

**Fix.** Invert the default: an unparseable response is a failure. Also check the HTTP status
explicitly before parsing (currently only `!= 200 && != 202` is rejected at `:456`).

### 7.9 (High) Lost-wakeup race in the VIP monitoring loop

**Location:** `vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:127-217`.

```java
// startMonitoringJob
monitoringQueue.add(monitoringMap);              // :133
if (!isRunning) { synchronized (this) { if (!isRunning) { isRunning = true; emProxyService.monitoringLoop(); } } }  // :135-142
...
// monitoringLoop
while (!monitoringQueue.isEmpty()) { … }         // :148
isRunning = false;                               // :216
```

The `isRunning = false` at `:216` is outside the `synchronized (this)` block. Interleaving:

1. Loop thread evaluates `!monitoringQueue.isEmpty()` → false, is about to exit.
2. Request thread adds a new job at `:133`, reads `isRunning == true` at `:135`, and does **not**
   start a loop.
3. Loop thread sets `isRunning = false` at `:216` and terminates.

The job sits in `monitoringQueue` forever. The user's VIP execution is never polled, never reaches
`processFinishedJob`, and its outputs are never imported — with no error anywhere.

Secondary: the loop does `Thread.sleep(10000)` *per queued execution* (`:197`) inside a loop that then
busy-waits another `sleepTime` (20 s, `:208-214`), so with N concurrent executions each poll cycle
takes `10N + 20` seconds. And the whole state is in-memory, so a restart drops everything (partly
mitigated by `ExecutionMonitoringResumptionRunner`).

**Fix.** Set `isRunning = false` inside the same `synchronized (this)` block and re-check the queue
under the lock before clearing the flag; or replace the whole hand-rolled scheduler with a
`ScheduledExecutorService` fixed-rate task that drains a persistent work table.

### 7.10 (Medium) NPE in `finally` masks the real failure

**Location:** `dataset/service/DatasetDownloaderServiceImpl.java:283-292`.

```java
File tempDir = null;
try {
    tempDir = convertToNifti(dataset, pathURLs, converterToUse, downloadResult, subjectName);
    …
} finally {
    LOG.info("Deleting temporary conversion folder [{}]", tempDir.getAbsolutePath());  // :290
    FileUtils.deleteQuietly(tempDir);
}
```

If `convertToNifti` throws (it declares `RestServiceException, IOException`, and can also throw NPE —
see below), `tempDir` is still `null` and the `finally` throws `NullPointerException`, **replacing**
the original exception. The operator sees an NPE instead of "PACS unreachable" or "conversion
failed". The temp directory also leaks.

Inside `convertToNifti` (`:302-335`) there is a second bug:

```java
File[] files = resultFolder.listFiles();
if (files == null || files.length == 0)
    downloadResult.update("No NIfTI files found after conversion.", DatasetDownloadError.ERROR);  // :328 — records but does not return
for (File file : files)   // :330 — NPE when files == null
```

The null check records an error and falls through into the loop. A third: line 274,
`dataset.getDatasetExpressions().get(0)` throws `IndexOutOfBoundsException` for a dataset with no
expressions (the getter at `Dataset.java:274-279` returns an empty list rather than null, so this is
reachable).

**Fix.** Guard the `finally` with `if (tempDir != null)`; `return` after the `files == null` check.

### 7.11 (Medium) BIDS zip staging never cleaned

**Location:** `bids/controller/BidsApiController.java:131-163`.

`tmpFile` (`/tmp/<userId>/<yyyyMMddHHmmss>/`) and `fileDir` (a full `FileUtils.copyDirectory` copy of
the requested BIDS subtree, `:142`) are created per request. Only `zipFile` is removed in the
`finally` (`:162`). The uncompressed copy and its parent directory remain. Every BIDS download
therefore leaves a full duplicate of the exported tree on the container's `/tmp`. For a
multi-gigabyte study this fills the disk within a handful of downloads, and `/tmp` is where the NIfTI
conversion staging also lives — so the failure mode is "imports and downloads both stop working".

**Fix.** `FileUtils.deleteQuietly(tmpFile)` in the `finally`; or stream the zip directly from the
source tree without the intermediate copy (the `zip()` helper at `:238` already walks a directory —
point it at `fileToBeZipped`).

### 7.12 (Medium) Zip-slip via unsanitised names in sorted exports

**Location:** `dataset/service/DatasetDownloaderServiceImpl.java:215-263`.

```java
if (sorting.contains("study"))   path += "/Study_"   + …getStudy().getName()   + "_id_" + …;   // :227
if (sorting.contains("subject")) path += "/Subject_" + …getSubject().getName() + "_id_" + …;   // :231
if (sorting.contains("exam"))    path += "/Exam_"    + …getComment()           + "_id_" + …;   // :235
```

No sanitisation. That `path` becomes `datasetFilePath`, which is prepended to the entry name
**after** the name itself has been sanitised:

```java
// download/WADODownloaderService.java:201-205
name = name.replaceAll("[^a-zA-Z0-9\\.\\-]", "_");     // sanitise
if (datasetFilePath != null) name = datasetFilePath + File.separator + name;   // then prepend unsanitised
```

and lands in `new ZipEntry(name + ".dcm")` (`WADODownloaderService.java:490,509,519`). The same
applies on the non-DICOM branch (`utils/DatasetFileUtils.java:222-229`).

An examination comment or study name containing `../../` therefore produces a zip whose entries
escape the extraction root — classic zip-slip, exploited on the *victim's* machine when they unpack
the export. Examination comments are free text set by any user with import rights
(`examination/service/ExaminationServiceImpl.java:317`).

Note the contrast: `getDatasetFilepath` (`:371-383`) *does* sanitise with
`replaceAll("[^a-zA-Z0-9_\\-]", "_")` and truncates at 255 — so the correct pattern exists three
methods away in the same file.

**Fix.** Apply `shapeForPath`-style sanitisation (the one at
`processing/service/ProcessingDownloaderServiceImpl.java:225-231`) to every segment of `path`, and
validate every `ZipEntry` name before `putNextEntry`.

### 7.13 (Medium) `IndexOutOfBoundsException` on paged dataset listing

**Location:** `dataset/service/DatasetServiceImpl.java:339-381`.

For a non-admin user who has *any* center restriction, `findPage` loads **all** datasets across all
their studies into a `List` (`:365`), filters in Java (`:371-374`), then:

```java
datasets = datasets.subList(pageable.getPageSize() * pageable.getPageNumber(),
                            Math.min(datasets.size(), pageable.getPageSize() * (pageable.getPageNumber() + 1)));
```

`Math.min` bounds only the *to* index. If the filtered list has 5 elements and the client requests
page 3 with size 10, this is `subList(30, 5)` → `IllegalArgumentException: fromIndex(30) > toIndex(5)`
→ HTTP 500. Any user paging past the end of their own filtered result hits it. The unbounded load at
`:365` is also a memory risk (§9.1).

**Fix.** Clamp `fromIndex` to `Math.min(from, size)`, and — properly — push the center restriction
into the JPQL so the database does the paging.

### 7.14 (Medium) BIDS semaphore deadlock

**Location:** `bids/service/BIDSServiceImpl.java:185-192`.

```java
bidsTreeSemaphore.lockOrThrow(studyId);              // :188  acquires
Study study = studyRepo.findById(studyId).orElseThrow();  // :189  OUTSIDE the try
String studyName = study.getName();                  // :190
ShanoirEvent event = null;
try {  …  } finally { bidsTreeSemaphore.unlock(studyId); }   // :192 … :247
```

If `findById` throws `NoSuchElementException` (study not replicated yet, or already deleted), the
`finally` is never reached and the permit is never released. `BidsTreeSemaphore` keeps one `Semaphore`
per study id in a `ConcurrentHashMap` with no eviction, so that study's BIDS tree is **permanently
locked** for the lifetime of the JVM: every subsequent `exportAsBids`, `getBIDSStructureByStudyId`
(which waits 30 s then 409s, `bids/controller/BidsApiController.java:183-186`) and
`validateBidsByStudyId` fails.

A converse hazard: `BidsTreeSemaphore.unlock()` calls `semaphore.release()` unconditionally, even if
the caller never acquired. `java.util.concurrent.Semaphore.release()` *increases the permit count
beyond the initial value*, so a stray unlock permanently converts the mutex into a 2-permit semaphore
and two concurrent BIDS exports of the same study will interleave on the same directory tree.

**Fix.** Move `lockOrThrow` to be the last statement before `try`, and make `unlock` a no-op unless a
permit is held (track ownership, or use `ReentrantLock` which enforces this).

### 7.15 (Medium) Unguarded recursion / index access on the processing chain

`dataset/model/Dataset.java:442-448` (`getFirstRealInput`) and `:427-435` (`getCenterId`) both do
`getDatasetProcessing().getInputDatasets().get(0)` with no empty check, and `getFirstRealInput`
recurses with no cycle guard. Called from the download hot path
(`dataset/service/DatasetDownloaderServiceImpl.java:223`, `download/WADODownloaderService.java:197`)
and from security filtering (`dataset/security/DatasetSecurityService.java:762-765` recurses through
`filterDatasetList` in the same way). A processing created with zero inputs, or a
processing-output-fed-back-as-input cycle, produces `IndexOutOfBoundsException` or
`StackOverflowError` on download.

### 7.16 (Medium) Unvalidated query parameters in the DICOMWeb facade

`dicom/web/DICOMWebApiController.java:117-118`:

```java
int offset = Integer.valueOf(allParams.get(OFFSET));
int limit  = Integer.valueOf(allParams.get(LIMIT));
```

`NullPointerException` if the viewer omits `offset`/`limit` (both are optional in the DICOMWeb
QIDO-RS spec), `NumberFormatException` on non-numeric input → HTTP 500. There is also a semantic bug:
DICOMWeb `offset` is a *record* offset, but it is passed to `PageRequest.of(offset, limit)` as a
*page number*, so `offset=10&limit=20` returns records 200-219 rather than 10-29.

`:140-141` does `Long.valueOf(studyInstanceUID.substring(studyInstanceUID.lastIndexOf(".") + 1))` —
`NumberFormatException` on any UID whose last segment isn't numeric.

### 7.17 / 7.18 (Low)

- `configuration/RabbitMQDatasetsService.java:480` — `Float.valueOf(countProgress / countTotal)`,
  integer division, always 0 for `countTotal > 1`.
- `solr/service/SolrServiceImpl.java:309,331` — `indexationProgess` never incremented; reindex
  progress is stuck at 10%.
- `dicom/web/service/DICOMWebService.java:463-475` — a STOW-RS response reporting duplicate instances
  (`0xB306`/`0xB305`) raises `ShanoirException`. Re-sending an already-stored instance is the natural
  retry semantics for an idempotent store; treating it as an error makes import retries impossible.

---

## 8. Security & data-protection review

### 8.1 Access control — endpoints with no authorization annotation

Spring Security requires authentication for everything except three paths
(`configuration/security/SecurityConfiguration.java:81-85`), so all of these need a **valid Shanoir
JWT** — but none of them checks *which* studies the caller may see.

| Method | Path | Declared at | Risk |
|---|---|---|---|
| POST | `/datasetProcessing/complexMassiveDownload` | `processing/controler/DatasetProcessingApi.java:195` | **Critical** — SQLi (§7.1) |
| GET | `/carmin-data/path/{completePath}?action=content` | `vip/processingResource/controller/ProcessingResourceApi.java:46` | **High** — streams full DICOM/NIfTI for a resource id. Protected only by the unguessability of a `UUID.randomUUID()` (`vip/processingResource/service/ProcessingResourceServiceImpl.java:43`). Capability never expires and is shared with the external VIP platform. |
| GET | `/examinations/subject/{subjectId}/study/{studyId}` | `examination/controler/ExaminationApi.java:109` | **High** — IDOR. `ExaminationApiController.java:163-171` calls `findBySubjectIdStudyId` with **no filtering**, returning examination dates, comments and centers for any subject in any study. |
| GET | `/vip/execution/{processingId}/stdout` | `vip/execution/controler/ExecutionApi.java:88` | **High** — IDOR on a sequential `Long`. Pipeline stdout routinely contains subject names and file paths. |
| GET | `/vip/execution/{processingId}/stderr` | `vip/execution/controler/ExecutionApi.java:77` | **High** — same |
| GET | `/vip/execution/{identifier}` and `/{identifier}/status` | `vip/execution/controler/ExecutionApi.java:66,100` | Medium — VIP execution metadata for any identifier |
| GET | `/bids/studyId/{studyId}/studyName/{studyName}` | `bids/controller/BidsApi.java:48` | **High** — any user triggers a full BIDS materialisation (DICOM→NIfTI conversion of an entire study) onto the shared `/var/bids-data` volume. Unauthorised processing of personal data under GDPR Art. 5(1)(f), plus a trivial DoS amplifier. Note its sibling `refreshBids` *does* have `@PreAuthorize` (`:61`). |
| POST | `/solr` (facet search), `/solr/byIds` | `solr/controler/SolrApi.java:70,79` | Low — filtering is genuinely done in the Solr query (`solr/service/SolrServiceImpl.java:174-195`), but there is no defence in depth: a bug in `getStudiesCenter()` exposes the whole index. |
| GET | `/vip/pipeline`, `/vip/pipeline/{id}/{version}` | `vip/pipeline/controler/PipelineApi.java:40,51` | Low — proxies the VIP pipeline catalogue, no Shanoir data |
| GET | `/datasets/overallStatistics` | `dataset/controler/DatasetApi.java:370` | Low — **explicitly `permitAll()`** at `configuration/security/SecurityConfiguration.java:82`, i.e. reachable with no token at all. Returns platform-wide counts and total storage volume (`dataset/service/DatasetServiceImpl.java:545-560`). Intentional (welcome page) but should be documented as a public endpoint. |

### 8.2 Access-control design weaknesses (beyond missing annotations)

- **Post-hoc filtering.** ~20 endpoints fetch first and filter in Java via `@PostAuthorize` +
  `filterXxxList` (§4a). Beyond the performance cost, these methods *mutate the response list and
  return `true` unconditionally* — so if the filter method throws or the list type doesn't match,
  the annotation still passes. `filterDatasetList` (`dataset/security/DatasetSecurityService.java:770`)
  even throws `IllegalStateException` for a dataset with neither examination nor processing parent,
  turning a data-quality issue into a 500 on a read endpoint.
- **Two incompatible conventions.** `checkDatasetDTOPage` (`:735`) returns `false` → 403 for the whole
  page; `filterDatasetDTOList` (`:832`) silently drops rows. Both are used on
  similar-looking endpoints (`DatasetApi.java:137` vs `:171`). A reader cannot tell from the endpoint
  which behaviour they get.
- **`findDatasetsByStudycardId`** (`dataset/controler/DatasetApi.java:170-172`) has `@PostAuthorize`
  but **no `@PreAuthorize`** — the query runs for any authenticated user before filtering.
- **`hasRightOnExamination(String examinationUID, …)`** (`dataset/security/DatasetSecurityService.java:1093`)
  parses the UID and delegates. If `extractExaminationId` returns null for a malformed UID, the
  downstream `examinationRepository.findById(null)` behaviour is unspecified — worth a test.

### 8.3 Path traversal

- §7.2 — `exportBIDSFile`, **Critical**, directly exploitable.
- `FileSystemStorageService.loadExtraData` / `loadAcquisitionExtraData`
  (`shanoir-ng-storage/.../FileSystemStorageService.java:279,292`) build
  `Paths.get(baseDirDatasets, EXAMINATION + id, fileName)` with no normalisation, and `fileName`
  arrives as a `@PathVariable("fileName:.+")` from
  `datasetacquisition/controler/DatasetAcquisitionApiController.java:316` and the equivalent
  examination endpoint. Spring Security's `StrictHttpFirewall` blocks literal and encoded `..`
  segments by default, which is why I rate this **Medium (defence-in-depth)** rather than High — but
  the storage layer should not depend on the firewall for correctness.
- `dataset/controler/DatasetApiController.java:581-593` (`downloadByEventId`) concatenates the
  `eventId` path variable into a filename. It is ADMIN-only and constrained by the `.zip`/`.tsv`
  suffix, so impact is limited, but `eventId=../../../../var/backups/dump.zip` would read that file.

### 8.4 PHI / PII exposure

- **`/tmp/metadataExtraction.csv`** — §7.3, cross-user DICOM metadata leak. This is the clearest
  GDPR-relevant defect.
- **Entity serialised into logs.** `dataset/service/DatasetServiceImpl.java:506` writes a whole
  `Dataset` as JSON to the log file.
- **Subject names in log lines.** `configuration/RabbitMQDatasetsService.java:210-212,250-251` logs
  "Subject replicated in MS Datasets with ID: {} and **Name**: {}" at INFO on every subject
  replication. `bids/service/BIDSServiceImpl.java:225` logs subject names during BIDS export.
  Root log level for `org.shanoir` is INFO (`application.yml`), so these are on in production and
  land in `/var/log/shanoir-ng-logs/shanoir-ng-datasets.log`, which is a shared docker volume.
- **Long-lived PHI caches.** `dicom/web/StudyInstanceUIDAndSubjectNameHandler.java:105`
  (`examinationUIDToSubjectNameCache`) holds subject names in an unbounded map for up to 24 h.
- **Solr expert-mode query logged at WARN.** `solr/solrj/SolrJWrapperImpl.java:596` —
  `LOG.warn("Solr expert research : " + searchStr)` writes user search text (which is typically a
  subject name) to the log at WARN.
- **Hard-coded fake demographics.** `dicom/web/dto/mapper/ExaminationToStudyDTOMapper.java:56-57`
  returns `patientBirthDate = "01011960"` and `patientSex = "F"` for everyone. Not a leak, but it
  means the DICOMWeb facade emits *false* clinical metadata, which is its own risk in a research
  context.

### 8.5 Injection

- **SQL** — §7.1 (Critical). Also note `solr/repository/ShanoirMetadataRepositoryImpl.java:61`
  executes an arbitrary caller-supplied SQL string as a native query
  (`findSpecificSolrDoc(String)`); today all callers pass constants +
  `" LIMIT n OFFSET m"` (`solr/service/SolrServiceImpl.java:323`), so it is not exploitable, but the
  API shape invites a future injection.
- **Solr query language** — `solr/solrj/SolrJWrapperImpl.java:595-598`:
  ```java
  private void addExpertClause(SolrQuery query, String searchStr) {
      LOG.warn("Solr expert research : " + searchStr);
      query.addFilterQuery(searchStr);     // raw, unescaped
  }
  ```
  Reachable from `POST /solr` with `expertMode = true`. Because Solr `fq` clauses AND together, this
  does **not** bypass the study/center filter added at `:410`. But it does allow arbitrary Lucene /
  local-params syntax: `{!frange …}` and deep leading-wildcard queries are cheap to write and
  expensive to run — a straightforward authenticated DoS on the shared Solr instance. Additionally
  `addFilterQuery` (`:266-269`) interpolates filter values inside double quotes with **no escaping**
  of `"`, and `addFilterQueryForCenterStudy` (`:342`) does the same for center names, so a crafted
  facet value can restructure the boolean clause.
- **CSV / formula injection** — `dataset/service/DatasetServiceImpl.java:635-638` (see §7.3).
- **HTTP header injection** — `datasetacquisition/controler/DatasetAcquisitionApiController.java:325`
  sets `Content-Disposition: attachment;filename=` + unquoted, unescaped path variable. Same at
  `bids/controller/BidsApiController.java:156` (quoted, but the value is unescaped). Servlet
  containers strip CR/LF from header values, so this is mostly a filename-spoofing issue.
- **PACS URL injection** — `dicom/web/service/DICOMWebService.java:136,155,195,230,284,340`
  concatenate `studyInstanceUID`/`serieInstanceUID`/`sopInstanceUID` into the outbound URL with no
  encoding. These UIDs are resolved from the DB via the virtual-UID handlers before reaching here,
  which limits exposure, but `sopInstanceUID` and `frame` come straight from the request path
  (`dicom/web/DICOMWebApiController.java:334-341`). `frame` at least reaches the URL unvalidated.
  The `Accept` header *is* properly sanitised (`:356-365`) — good, and the same treatment should be
  applied to the UID segments.

### 8.6 Secrets handling

`src/main/resources/application.yml` contains `spring.datasource.password: password` in plain text
(production profile). S3 credentials, the Keycloak URL and the VIP client secret are correctly
externalised to environment variables. `.github/workflows/maven.yml:60-72` hard-codes
`SHANOIR_KEYCLOAK_PASSWORD: '&a1A&a1A'` and `VIP_CLIENT_SECRET: SECRET` — CI-only dummy values, but
they normalise the pattern.

### 8.7 Audit trail

`ShanoirEvent` gives a decent audit spine: downloads
(`dataset/service/DatasetDownloaderServiceImpl.java:197-205`), deletions, imports, copies and BIDS
exports all publish events with `KeycloakUtil.getTokenUserId()`. Gaps:

- The download event is published **after** the zip has been fully written and only on the success
  path (`:206` catches everything and throws instead). A download that fails halfway — after the
  user has already received several gigabytes of imaging data — is **not recorded at all**.
- The event records dataset ids but not which study/center they belonged to, so answering "who
  downloaded data from study X" requires a join against the current DB state.
- `/carmin-data/path/**` (the VIP data egress path) publishes a download event via
  `massiveDownload`, but attributes it to whichever token called it — for VIP that is the service
  account, so the human who launched the pipeline is not in the audit record.
- No event is published for `complexMassiveDownload`'s query itself, only for the resulting id list.

### 8.8 GDPR-relevant summary

For a platform handling identifiable neuroimaging: the SQLi (§7.1), the arbitrary file read (§7.2),
the shared metadata CSV (§7.3) and the unauthenticated BIDS materialisation (§8.1) each individually
constitute a personal-data breach risk. Subject names in INFO logs and in 24-hour in-memory caches
are lesser but real minimisation problems. Anonymisation itself is delegated to the
`org.shanoir.anonymization` module and to pseudonymisation at import time — this service's
contribution is `modifyDicomPatientInfo` (three copies, §5.5) which overwrites only `PatientName`
(0010,0010) and `PatientID` (0010,0020). It does **not** touch `PatientBirthDate` (0010,0030),
`PatientSex`, `AccessionNumber`, `InstitutionName`, `ReferringPhysicianName`, `StudyDescription`, or
private tags — and `findSerieMetadataOfStudy` explicitly requests `excludeprivate=false`
(`dicom/web/service/DICOMWebService.java:196`), i.e. private tags **are** forwarded to the viewer
despite the javadoc at `:185-187` claiming the opposite. Whether that is acceptable depends on
whether the data was anonymised at import; the code here provides no second line of defence.

---

## 9. Performance & scalability

### 9.1 Query patterns

- **Eager `datasetAcquisition`.** `dataset/model/Dataset.java:110` makes every dataset load pull its
  acquisition. `findByIdIn` for a 500-dataset download (`dataset/controler/DatasetApiController.java:420`)
  therefore issues at minimum 500 extra selects unless Hibernate batches them — and there is no
  `@BatchSize` or `hibernate.default_batch_fetch_size` anywhere in the module.
- **Unbounded in-memory paging.** `dataset/service/DatasetServiceImpl.java:365-379` loads every
  dataset of every study the user can see, then pages in Java. For an OFSEP-scale user with access to
  a large cohort this is a heap risk and a guaranteed slow query.
- **Per-row storage calls.** `examination/service/ExaminationServiceImpl.java:335-344`
  (`getExtraDataSizeByStudyId`) iterates every examination × every extra-data path and calls
  `storageService.getFileSizeExtraData` for each. This runs inside the
  `study-datasets-detailed-storage-volume` RPC listener (`configuration/RabbitMQDatasetsService.java:407`),
  so MS Studies blocks on it. With S3 storage each call is a network round-trip.
- **Solr center lookup.** `solr/service/SolrServiceImpl.java:241-262` calls
  `centerRepository.findAll()` on **every non-admin search** and then does a linear scan per center id
  (`findCenterName`, `:259-262`). O(studies × centers) per search request, plus a full table load.
- **Sequential PACS calls in a request thread.** `dataset/service/DatasetServiceImpl.java:607-620`
  (metadata CSV) and `download/WADODownloaderService.java:330-349`
  (`getDicomAttributesForAcquisition`) both loop over datasets making one blocking HTTP call each.
- Positive note: the rights-checking queries were clearly optimised recently — `findDatasetsForRights`
  (`dataset/repository/DatasetRepository.java:138-154`) and `findRightsDtoBaseById` (`:196-209`) are
  projection queries that avoid loading entities. That pattern should be extended to the download
  paths.

### 9.2 Memory behaviour on large exports

- **500 MB in-memory buffer per PACS download.**
  `download/WADODownloaderService.java:136-140` configures
  `maxInMemorySize(500 * 1024 * 1024)` on the shared `WebClient`, and `downloadFileFromPACS`
  (`:368-378`) does `.bodyToMono(byte[].class).block()` — the **entire** multipart response is
  materialised as a `byte[]` before a single byte reaches the zip. With N concurrent exports the
  worst case is N × 500 MB. There is no concurrency limit on export endpoints.
- The subsequent `MimeMultipart`/`ByteArrayDataSource` handling (`:487-522`) copies again, so peak
  usage is roughly 2× the response size per in-flight download.
- **`DICOMWebService` reads whole instances into `byte[]`** at `:245,290,347` before wrapping in a
  `ByteArrayResource`. For the OHIF frame endpoint this is per-frame, so acceptable; for
  `findInstance` it is per-instance.
- Streaming *is* done correctly for the file-system/S3 path (`utils/DatasetFileUtils.java:252-254`
  uses `StreamUtils.copy`), and the gzip-on-the-fly path correctly spools to a temp file rather than
  memory (`:232-245`). So the memory problem is specific to the PACS path.

### 9.3 Open Session In View

`spring.jpa.open-in-view` is **not set** in `shanoir-ng-datasets/src/main/resources/application.yml`,
so it defaults to `true`. Three sibling services (`import`, `users`, `studies`) explicitly set it to
`false`. Consequence: a JDBC connection from the 70-connection Hikari pool
(`hikari.maximum-pool-size: 70`, `minimum-idle: 70`) is held for the **entire** duration of every
request — including a `massiveDownloadByStudy` that streams several gigabytes over minutes. 70
concurrent large downloads exhaust the pool and every other request in the service blocks.

This is almost certainly the reason `ProcessingResourceApiController.printStats`
(`vip/processingResource/controller/ProcessingResourceApiController.java:88-101`) logs
`getThreadsAwaitingConnection()` on every VIP fetch.

Turning OSIV off is the right fix, but it will expose the lazy traversals in
`DatasetDownloaderServiceImpl.getDatasetDownloadPath` (`:226-259`) and elsewhere — those need explicit
fetch joins or a projection DTO first. Treat it as a two-step change.

### 9.4 Solr indexing cost

- **`indexAll` empties the index first.** `solr/service/SolrServiceImpl.java:113-123` →
  `cleanOldIndex` (`:347`) → `deleteAll()` → `deleteByQuery("*:*")` + commit, *then* rebuilds. Search
  returns nothing for the whole duration of a full reindex. On a production-sized DB (10 queries ×
  100 000-row partitions) that is minutes to hours of broken search.
- **Commit per batch.** `solr/solrj/SolrJWrapperImpl.java:145,150,155,160,165` calls
  `solrClient.commit()` after every add/delete, including the single-document
  `addToIndex`. Hard-committing per document is the classic SolrJ anti-pattern; `commitWithin` or
  Solr's autoCommit should be used instead. `indexDataset` (`SolrServiceImpl.java:157`) is called
  per-dataset during import, so a 500-image import triggers 500 hard commits.
- **`READ_UNCOMMITTED`.** `solr/service/SolrServiceImpl.java:156` declares
  `@Transactional(isolation = Isolation.READ_UNCOMMITTED, propagation = Propagation.REQUIRES_NEW)` on
  `indexDataset`. This is presumably to read rows written by an in-flight import transaction. It means
  Solr can index rows that are subsequently rolled back, leaving documents in the index that
  reference non-existent datasets. There is no reconciliation job.
- **Leading-wildcard search.** `solr/solrj/SolrJWrapperImpl.java:600-622` builds
  `(field:*term*)` across 12 text fields for every term of a free-text search. Leading wildcards
  cannot use the index; this is a full scan of the term dictionary per field per term.

### 9.5 Blocking I/O and concurrency limits

- `WADODownloaderService` uses WebFlux `WebClient` but immediately `.block()`s
  (`:371,383`) — reactive machinery with none of the benefits, plus the 500 MB buffer.
- `spring.threads.virtual.enabled: true` in Java 21 means request handling is on virtual threads.
  Combined with the `synchronized (this)` block at
  `vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:136` (which, on JDK 21, **pins**
  the carrier thread for the duration) and a 100-platform-thread `asyncExecutor`
  (`configuration/AsyncConfiguration.java:33`), the threading model is three overlapping strategies at
  once. Nothing is obviously broken, but nothing is obviously bounded either.
- **No rate limit or concurrency cap on export endpoints.** The only guard is `DATASET_LIMIT = 500`
  on the *number of datasets per request* (`dataset/controler/DatasetApiController.java:163`) — and
  even that is bypassed when `sortingForProcessingOutputs` is supplied (`:414`:
  `if (size > DATASET_LIMIT && Objects.isNull(sortingForProcessingOutputs))`). A caller who passes any
  `sorting` value can request unlimited datasets.
- `dcm4chee-arc.dicom.web.http.client.max.total: 500` and `max.per.route: 500` — the PACS connection
  pool is effectively unbounded relative to what dcm4chee can serve.

---

## 10. Technical debt inventory

Ranked by (risk × reach) / cost.

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | Fix the SQL injection (§7.1) and add `@PreAuthorize` to the 9 unprotected endpoints (§8.1) | **2–3 days** | Mechanical once the allow-list model is agreed |
| 2 | Fix the BIDS path traversal (§7.2) and the prefix-collision check | **0.5 day** | `Path.toRealPath()` + `startsWith` |
| 3 | Replace `/tmp/metadataExtraction.csv` with per-request temp files + proper CSV escaping (§7.3) | **0.5 day** | `opencsv` already a dependency |
| 4 | Repair the 6 broken `@Transactional` self-invocations (§5.1) | **1 day** | Self-inject `@Lazy` proxy, or extract to a `…TransactionalService` (the pattern already exists) |
| 5 | Add a reflective "every endpoint is annotated" test | **0.5 day** | Highest leverage single test in the module |
| 6 | RabbitMQ reliability: DLQ + bounded retry + backoff for all 15 listeners; fix the `reload-bids` NPE loop (§7.7); remove `@Async` from `copyDatasetsToStudy` (§7.6) | **1 week** | Requires a broker-config decision shared with the other services |
| 7 | Make imports idempotent (dedup key on `importer-queue-dataset`) | **1 week** | Prerequisite for enabling retries safely |
| 8 | Stream PACS downloads instead of buffering 500 MB (§9.2) | **3–5 days** | `bodyToFlux(DataBuffer)` → zip, or fall back to HttpClient5 streaming |
| 9 | Turn off OSIV and add explicit fetch joins / projections (§9.3) | **1–2 weeks** | Must be done together with #8 to be safe |
| 10 | Solr: incremental reindex (index-to-alias, swap) instead of delete-all; `commitWithin` instead of per-doc commit (§9.4) | **1 week** | Also removes the `READ_UNCOMMITTED` hack if reindex becomes cheap |
| 11 | Deduplicate the 10 Solr projection queries into one templated query (§5.5) | **2–3 days** | ~330 LOC deleted |
| 12 | Remove `@WithMockKeycloakUser` from production code and move `spring-security-test` to test scope (§7.5) | **0.5 day** | Backend-wide win |
| 13 | Delete dead code: `ExaminationsConsistencyChecker`, the six `return null` DICOMWeb endpoints, `score/`, `findAllAsSolrDoc` (§5.4) | **1 day** | ~900 LOC |
| 14 | Consolidate the three `modifyDicomPatientInfo` implementations and the three HTTP client stacks | **3–5 days** | |
| 15 | Add Jacoco with a ratcheting coverage gate to CI | **1 day** | Currently no coverage is measured at all |
| 16 | Fix `BidsTreeSemaphore` (§7.14) and `BidsValidationAwaiter` leak (§5.3) | **1 day** | |
| 17 | Fix the VIP monitoring lost-wakeup race and replace the hand-rolled loop with a scheduled drain (§7.9) | **1 week** | |
| 18 | Retire `spring-data-solr` 4.3.15 (EOL 2020) by replacing `SolrResultPage` with a local DTO | **2 days** | |
| 19 | Split `DatasetSecurityService` (1 209 LOC, 40+ near-duplicate methods) | **1 week** | |

**Rough total to a defensible baseline (items 1–5, 12, 13, 15): ~2 weeks.**
**To a healthy service (all items): ~3 months of one engineer.**

---

## 11. Improvement roadmap

### Quick wins (< 1 day each)

1. **Add the missing `@PreAuthorize` annotations** to the nine endpoints in §8.1. For
   `complexMassiveDownload` and `/carmin-data/path/**` this is the difference between "exploitable"
   and "needs a second bug".
2. **Fix `exportBIDSFile`** with `toRealPath()` + `Path.startsWith` (§7.2).
3. **Fix `BIDSServiceImpl.deleteBidsForStudy`** — `ifPresent` instead of `orElse(null)` (§7.7).
   Stops an infinite redelivery loop.
4. **Per-request temp file** for the metadata CSV (§7.3).
5. **Guard the `finally`** in `manageDatasetDownload` and `return` after the null-array check in
   `convertToNifti` (§7.10).
6. **Delete the BIDS staging directory** in the `finally` of `exportBIDSFile` (§7.11).
7. **Replace `@WithMockKeycloakUser`** with `SecurityContextUtil.initAuthenticationContext` (§7.5).
8. **Make `BIDSServiceImpl.formatter` a local `DateTimeFormatter`** (§5.3).
9. **Sanitise the sorted-export path segments** with the existing `shapeForPath` (§7.12).
10. **Escape the Solr expert clause** with `ClientUtils.escapeQueryChars`, or restrict expert mode to
    ADMIN (§8.5).
11. **Add `@PreAuthorize` completeness test** (§6.5.3) — one file, permanent protection.
12. **Set `spring.jpa.open-in-view: false`** — *not* a quick win on its own; listed here only to note
    that the one-line config change must **not** be made without item 9 of §10.

### Medium (1–2 weeks each)

1. **Eliminate the SQL injection properly.** Replace the `JsonNode` filter DSL with a typed
   `ExtractionFilterDTO` whose field selector is an enum, and bind all values. Add the injection
   tests. This also makes the feature documentable.
2. **RabbitMQ reliability baseline.** Declare a DLX per queue, configure
   `spring.rabbitmq.listener.simple.retry` with exponential backoff and `max-attempts`, replace
   blanket `AmqpRejectAndDontRequeueException` with "retry N times then DLQ", and add a DLQ-depth
   metric. Coordinate with the other services since `RabbitMQConfiguration` is shared.
3. **Import idempotency.** Add a `processed_message` table keyed on the import job's natural id and
   short-circuit redeliveries. This is a prerequisite for #2 to be safe.
4. **Stream the PACS download path.** Remove the 500 MB buffer; pipe `DataBuffer`s straight into the
   `ZipOutputStream`. Add a semaphore capping concurrent exports.
5. **Test the download path properly.** Zip-content assertions, failure injection (PACS 500,
   conversion timeout, malformed expression), and the ten tests from §6.5.
6. **Incremental Solr indexing.** Index into a new collection and swap the alias, so search is never
   empty; move to `commitWithin`; add a nightly reconciliation that deletes orphaned documents.
7. **Fix the VIP monitoring scheduler** (§7.9) and persist monitoring state so restarts are safe.

### Large (architectural)

1. **Extract a `shanoir-ng-pacs` service.** Move `dicom/web/`, `download/`, and the DICOMWeb facade
   behind a narrow interface. It has its own HTTP client, its own caches, its own cron, and its only
   dependency on the rest of the module is examination→UID resolution. This is the cleanest seam in
   the codebase (~5 800 LOC) and it isolates the highest-memory workload from the transactional core.
2. **Extract `shanoir-ng-export`.** Massive download, BIDS export, statistics, CSV extraction and the
   VIP `carmin-data` egress are all long-running, memory-hungry, and currently share a connection
   pool with interactive traffic. Splitting them lets you scale and rate-limit them independently and
   removes the OSIV/connection-pool coupling entirely. It also naturally forces the export code to
   read through an API rather than lazily walking the entity graph.
3. **Move Solr indexing to an outbox/CDC pipeline.** Today indexing is invoked inline from ~10 call
   sites with mixed `@Async`/`@Transactional` semantics and a `READ_UNCOMMITTED` escape hatch. A
   transactional outbox table drained by a single indexer removes the isolation hack, makes indexing
   retryable, and removes the "index rows that later roll back" class of bug.
4. **Introduce a rights-aware repository layer.** Replace the ~20 `@PostAuthorize` +
   `filterXxxList` pairs with query-level filtering (a Hibernate filter or a mandatory
   `UserRights`-derived predicate on every finder). This kills a whole category of authorization bug
   and most of the post-hoc filtering cost, and would shrink `DatasetSecurityService` by more than
   half.
5. **Split `Dataset`'s 18-way JOINED inheritance.** 18 subtypes × JOINED means every polymorphic query
   is an 18-way `LEFT JOIN`. Most subtypes add zero or one column. Consider `SINGLE_TABLE` for the
   thin subtypes, or a `@Any`-style discriminator with modality-specific detail tables loaded on
   demand. Big change; measure first.

---

## 12. Future work & feature directions

Motivated by what the code already reaches for:

- **Finish the DICOMWeb facade.** Six endpoints return `null` today
  (`dicom/web/DICOMWebApiController.java:110,193,404,422,428,441`), including QIDO-RS
  `/instances` and STOW-RS. A complete, standards-conformant DICOMWeb surface would let Shanoir act as
  a queryable archive for third-party tools (XNAT, Flywheel, OHIF outside Shanoir, research
  pipelines) without going through the proprietary export path. The `stow` stub's javadoc (`:431-437`)
  already sketches the design.
- **Make `/carmin-data/path` a proper CARMIN implementation.** `exists`, `list`, `properties`, `md5`
  are all 501 (`vip/processingResource/controller/ProcessingResourceApiController.java:59`).
  Implementing `md5` in particular would let VIP verify transfers and enable resumable/idempotent
  fetches. Pair this with expiring, scoped capability tokens instead of never-expiring UUIDs (§8.1).
- **BIDS as a first-class output rather than a materialised side-effect.** Today BIDS export writes a
  full duplicate tree to a shared volume with a per-study mutex, and the derived NIfTI is regenerated
  from scratch. A BIDS *view* (generated manifest + streaming zip, with NIfTI cached in object
  storage keyed by dataset+converter) would remove the semaphore, the disk growth, and the
  "one export at a time per study" limit. The `BidsElement`/`BidsFolder`/`BidsFile` model
  (`bids/model/`) is already the right abstraction for this.
- **BIDS derivatives for VIP outputs.** The service already ingests pipeline outputs
  (`vip/output/handler/`) and already knows how to write BIDS. Emitting `derivatives/` per pipeline
  would make Shanoir outputs directly consumable by the BIDS-Apps ecosystem.
- **Quality-card results as queryable data.** `studycard/model/condition` + `rule` + `field`
  (2 291 LOC) implements a real rule engine whose results currently only tag subjects. Persisting
  per-rule outcomes would enable cohort queries like "all examinations failing rule X", which is what
  OFSEP-style multi-center QC actually needs.
- **DICOM SEG / SR as a supported modality end-to-end.** `DicomSEGAndSRImporterService` (424 LOC) and
  `SrDataset` exist, and `SeriesInstanceUIDHandler.findSeriesToVirtualUIDsOfAcquisition`
  (`dicom/web/DICOMWebApiController.java:210-215`) already handles acquisitions spanning multiple
  PACS series for SEG/SR. Completing this (viewer round-trip, export, Solr facets) would let Shanoir
  store segmentations natively rather than as opaque processed datasets.
- **Split the service** — see §11 Large. Realistically this is the thing that unblocks everything
  else: the module is at the size where a single test run, a single deployment and a single
  connection pool are all bottlenecks.

---

## 13. Appendix

### A. Largest files (main source)

| LOC | File |
|---|---|
| 1 209 | `dataset/security/DatasetSecurityService.java` |
| 855 | `bids/service/BIDSServiceImpl.java` |
| 721 | `importer/service/DicomImporterService.java` |
| 685 | `dataset/service/DatasetServiceImpl.java` |
| 672 | `dicom/web/service/DICOMWebService.java` |
| 666 | `dataset/controler/DatasetApiController.java` |
| 657 | `datasetacquisition/model/mr/MrProtocol.java` |
| 647 | `solr/solrj/SolrJWrapperImpl.java` |
| 606 | `configuration/RabbitMQDatasetsService.java` |
| 602 | `studycard/model/VM.java` |
| 581 | `datasetacquisition/model/pet/PetProtocol.java` |
| 564 | `dataset/model/Dataset.java` |
| 549 | `download/WADODownloaderService.java` |
| 547 | `importer/strategies/protocol/MrProtocolStrategy.java` |
| 513 | `datasetacquisition/model/mr/MrProtocolMetadata.java` |
| 488 | `examination/model/Examination.java` |
| 444 | `dicom/web/DICOMWebApiController.java` |
| 439 | `vip/output/handler/OFSEPSeqIdHandler.java` |
| 427 | `importer/service/ImporterService.java` |
| 426 | `solr/repository/ShanoirMetadataRepositoryCustom.java` |

### B. Complexity hotspots

| Location | Why |
|---|---|
| `dataset/security/DatasetSecurityService.java` (whole file) | 40+ methods, ~15 of them near-duplicates differing only in parameter type; the single place where an authorization mistake is invisible |
| `configuration/RabbitMQDatasetsService.java:452-579` | `copyDatasetsToStudy` — 127-line method, 6 mutable counters, 4 nested catch blocks, a role switch that mutates the security context, and an `@Async` that breaks its own error handling |
| `dataset/service/DatasetDownloaderServiceImpl.java:127-335` | Three code paths (DICOM passthrough / DICOM→NIfTI / other) with different error semantics, sharing five mutable maps threaded through a 10-parameter method |
| `processing/service/ProcessingDownloaderServiceImpl.java:234-320` | Hand-rolled SQL DSL over `JsonNode` — the Critical finding |
| `solr/service/SolrServiceImpl.java:308-341` | Nested `for`/`while(true)` with manual offset paging and progress arithmetic that doesn't work |
| `vip/executionMonitoring/service/ExecutionMonitoringServiceImpl.java:127-217` | Hand-rolled scheduler with a visible race |
| `studycard/model/condition/` + `rule/` + `field/` (2 291 LOC, 19 classes) | Rule engine with zero direct tests |
| `importer/service/DicomImporterService.java` (721 LOC) | Import orchestration + 3 AMQP RPCs + 2 caches + 1 cron in one class |

### C. TODO / FIXME / XXX / HACK inventory

The module is unusually clean here — only 4 markers:

| Location | Marker |
|---|---|
| `vip/processingResource/controller/ProcessingResourceApiController.java:59` | `// TODO implement those actions` (exists/list/md5/properties → 501) |
| `dicom/web/dto/mapper/ExaminationToStudyDTOMapper.java:52` | `// @TODO optimize here: not ask the database for each subject id, use a cached list?` |
| `dicom/web/dto/mapper/ExaminationToStudyDTOMapper.java:56` | `studyDTO.setPatientBirthDate("01011960"); // @TODO not yet in ms datasets database` |
| `dicom/web/dto/mapper/ExaminationToStudyDTOMapper.java:57` | `studyDTO.setPatientSex("F"); // @TODO not yet in ms datasets database` |

Plus 2 `@Deprecated` members (`dataset/model/Dataset.java:498,508` — `getImportedStudyId`/`setImportedStudyId`,
still referenced by the copy constructor at `:235`).

The low marker count is misleading: the real debt is expressed as commented-out code
(`examination/schedule/ExaminationsConsistencyChecker.java:96`), empty catch blocks with prose
comments (`studycard/service/CardsProcessingService.java:113,160` — `// too bad`), and
apologetic javadoc (`configuration/RabbitMQDatasetsService.java:197-200`).

### D. Dependency observations

From `shanoir-ng-datasets/pom.xml`:

| Dependency | Version | Note |
|---|---|---|
| `org.springframework.data:spring-data-solr` | 4.3.15 | **EOL since 2020**, retained for one class. `pom.xml:84-86` documents this: *"legacy dependency… only remains for SolrResultPage for facet search"*. Should be replaced with a local DTO. |
| `org.apache.httpcomponents:httpmime` | 4.5.14 | HttpClient **4.x** MIME library pulled in alongside `httpclient5` — two generations of Apache HttpClient in the same jar. |
| `org.apache.solr:solr-solrj` | 9.4.1 | Reasonably current (9.x line). |
| `org.apache.commons:commons-compress` | 1.26.0 | Current enough; note 1.26.0 was the fix release for CVE-2024-25710 / CVE-2024-26308, so do not downgrade. |
| `com.opencsv:opencsv` | 5.7.1 | Present but **not used** where it should be — the metadata CSV is built with string concatenation (§7.3). |
| `spring-boot-starter-webflux` | 3.4.0 | Version pinned explicitly rather than inherited from the Boot BOM (`pom.xml:96-100`) — a drift hazard when Boot is upgraded. |
| `spring-security-test` (inherited from `shanoir-ng-back/pom.xml:117-121`) | Boot-managed | **compile scope in production**, with the comment "do not put scope test here: compile errors". Caused by §7.5. |
| `joda-time` (via `org.joda.time.DateTime`) | transitive | Used at `dataset/service/DatasetDownloaderServiceImpl.java:352`, `bids/controller/BidsApiController.java:135` alongside `java.time` — two date libraries. |
| `org.assertj.core.util.Lists` | test lib | Imported in **main** source at `processing/service/ProcessingDownloaderServiceImpl.java:33` and used at `:316-317`. Another test dependency leaking into production. |
| `org.springframework.mock.web.MockMultipartFile` | spring-test | Imported in **main** source at `importer/service/ImporterService.java:55`, used at `:205`. Third test-scope leak. |

### E. Checkstyle notes

- Config: `shanoir-ng-back/checkstyle.xml`, 72 `<module>` entries. Suppressions
  (`shanoir-ng-back/suppressions.xml`) are minimal and reasonable: `MethodName` for `*Repository.java`
  (Spring Data derived-query names), `Header` for two vendored EEG parser packages, `FinalClass` and
  `HideUtilityClassConstructor` for `*Application.java`.
- **Checkstyle is skipped in the main build.** `.github/workflows/maven.yml:56` runs
  `mvn install -Dcheckstyle.skip=true`. It runs in a separate job
  (`.github/workflows/checkstyle.yml`) which iterates modules with `set +e` and aggregates the exit
  code — so it does gate PRs, but the two workflows can disagree about what "green" means.
- **No Jacoco.** Despite Jacoco 0.7.9 being mentioned in the project's tooling list, no
  `jacoco-maven-plugin` appears in `shanoir-ng-back/pom.xml`, and no coverage report or threshold is
  produced in CI. There is consequently no objective coverage number for this service — the 10.1%
  class ratio in §6.1 is a structural proxy, not measured line coverage.
- `mvn install` in `maven.yml` does run the test phase, so the 172 tests do execute on every PR to
  `develop`. There is no separate integration-test stage; the four `*TestIT` classes are
  `@SpringBootTest`s that run in the same phase.

---

*Audit performed by static reading of `shanoir-ng-datasets` at `867e53290`. No build was executed and
no source was modified. Claims marked "inferred" reflect reasoning about runtime behaviour that was
not observed directly — notably the OSIV default (§9.3), the `StrictHttpFirewall` mitigation in §8.3,
and MariaDB's `allowMultiQueries` default in §7.1. Everything else is directly attested by the cited
lines.*
