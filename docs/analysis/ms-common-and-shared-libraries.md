# Shanoir-NG — Shared Library Layer Audit

**Scope:** `shanoir-ng-ms-common`, `shanoir-ng-study-rights`, `shanoir-ng-anonymization`, `shanoir-ng-exchange`, `shanoir-ng-storage`, `shanoir-ng-keycloak-auth`
**Repository:** `/home/jamesbardet/Documents/code/shanoir-ng` @ `867e53290` (develop)
**Method:** static read-only analysis. Every claim is cited as `path:line`. Inferences are marked *(inferred)*.
**Not covered here:** the service modules themselves (datasets, studies, users, import, preclinical, front) except where they consume the shared layer.

---

## 1. Executive summary

### What this layer is

Six Maven modules, 11,877 lines of Java, 127 main classes, **4 test classes** (of which only one actually executes assertions against real logic). They are not "utility libraries" — they are the platform's *distributed runtime contract*:

- `ms-common` owns the **entire RabbitMQ topology** (65 queue names, 2 exchanges, both listener-container factories), the shared event model, the shared exception/error model, the DTOs exchanged between all services, the Keycloak token helpers, and the mechanism that fabricates an ADMIN security context for message consumers.
- `study-rights` **is the authorization layer** for datasets and import: it owns the `StudyUser` JPA entity, the replicated `study_user` table that lives in four separate databases, and the AMQP consumer that keeps those replicas in sync.
- `anonymization` **is the patient-privacy boundary**: a single 691-line class plus an `.xlsx` rule table, executed both server-side (ms-import) and client-side (ShanoirUploader).
- `storage`, `exchange`, `keycloak-auth` are smaller but each owns a security-relevant surface (filesystem/S3 paths, patient pseudonym derivation, and the Keycloak login flow respectively).

### Health verdict

**Poor, and structurally so.** This is not a matter of missing polish. Three of the six modules have zero executable tests (`study-rights`, `storage`, `keycloak-auth`); the anonymization module's only "test" is a `main()` method pointing at `/Users/mkain/Desktop/sample1/IMAGES` (`shanoir-ng-anonymization/src/test/java/org/shanoir/anonymization/anonymization/AnonymizationTest.java:41`). The messaging layer has no dead-letter queues, no retries, no publisher confirms and no consistent error contract, while carrying authorization-state replication. The anonymization engine silently mis-handles every compound DICOM PS3.15 action code and never descends into sequences. And the module versioning scheme is accidentally coupled to the Spring Boot version number.

There *is* real craft in places — the DICOM `TM` parser and its test (`shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/dateTime/DateTimeUtils.java:59-79`), the S3 multipart abort-on-failure handling (`shanoir-ng-storage/src/main/java/org/shanoir/ng/storage/S3StorageService.java:744-752`), the anonymization stats accumulator. These are recent, careful additions. They sit on top of a decade-old foundation that has never been tested.

### Top findings, ranked

| # | Severity | Finding | Anchor |
|---|---|---|---|
| 1 | **Critical** | RabbitMQ is reachable on the host (`5672`, `15672`) with `guest/guest`, no message converter is configured (so Java deserialization is enabled on several queues), and ~43 listener methods call `SecurityContextUtil.initAuthenticationContext("ROLE_ADMIN")`. Anyone who can reach the broker gets admin-level command execution across all services. | `docker-compose.yml:74-83`, `SecurityContextUtil.java:50-52`, no `MessageConverter` bean anywhere |
| 2 | **Critical** | Anonymization: compound PS3.15 action codes (`X/Z`, `X/D`, `Z/D`, `X/Z/D`, `X/Z/U*`) are not implemented — `getFinalValueForTag` falls through and **blanks the tag**. 49 tags in the shipped profiles use them, including `Referenced Image Sequence` and `Source Image Sequence` which should get UID re-mapping. | `AnonymizationServiceImpl.java:527-549`, `anonymization.xlsx` rows 412/535 |
| 3 | **Critical** | Anonymization never recurses into DICOM sequences. `datasetAttributes.tags()` returns top-level tags only, so nested PHI (e.g. inside `RequestAttributesSequence`, `OriginalAttributesSequence`, private SQ items) survives untouched — despite the profile's own Legend defining `K` as "keep […] cleaned for sequences". | `AnonymizationServiceImpl.java:275`, `anonymization.xlsx` Legend row 6 |
| 4 | **Critical** | Anonymization fails **open** on I/O error: `catch (final IOException exc) { LOG.error(...) }` leaves the original, non-anonymized file on disk and reports success to the caller. | `AnonymizationServiceImpl.java:332-334` |
| 5 | **High** | Study-rights replication is a dual write inside a JPA transaction with no outbox and no publisher confirms; failures throw `AmqpRejectAndDontRequeueException` and the message is **discarded** (no DLQ). A failed revocation is permanent stale access. | `StudyUserUpdateBroadcastService.java:41-47`, `RabbitMqStudyUserService.java:65-67`, `StudyUserServiceImpl.java:128-144` |
| 6 | **High** | `StudyRightsService.hasRightOnCenter` dereferences `founded` before its own null check, and grants access on an **empty** center list without checking `isConfirmed()` or any right — inconsistent with every sibling method. | `StudyRightsService.java:81-88` |
| 7 | **High** | `RabbitMqStudyUserService.receiveStudyUsers` calls `mapper.registerModule(...)` on the shared Spring `ObjectMapper` **on every message**, from a 10–100-consumer container. Jackson mapper reconfiguration is not thread-safe once in use, and the module list grows without bound. | `RabbitMqStudyUserService.java:59-61` + `RabbitMQDatasetsService.java:155` |
| 8 | **High** | `ShanoirNgPostAuthAuthenticator` shares a static `SimpleDateFormat` across concurrent Keycloak logins and makes a blocking HTTP call with no timeouts and a never-closed `HttpClient`, on the login path. | `ShanoirNgPostAuthAuthenticator.java:86,170-181` |
| 9 | **High** | `IdentifierCalculator.calculateSHA` derives patient pseudonyms with **SHA-1**, no salt, from `firstName+lastName+birthDate`, truncated to 14 characters of a hex/decimal-interleaved string. Trivially brute-forceable. One overload keys on `Date.toString()`, which is locale- and timezone-dependent. | `IdentifierCalculator.java:88-107,82-85` |
| 10 | **High** | Path traversal in `FileSystemStorageService`: filenames are URL-decoded and then joined without normalisation or containment check, on both read and write. | `FileSystemStorageService.java:214, 258-260` |
| 11 | **Medium** | `shanoir-ng-back` declares no `<version>`, so every backend module's artifact version is inherited from `spring-boot-starter-parent` (currently 3.4.0). Nine poms hardcode `3.4.0`. Upgrading Spring Boot silently breaks the build. | `shanoir-ng-back/pom.xml:20-31`, `shanoir-ng-ms-common/pom.xml:21-26` |
| 12 | **Medium** | Six queue-name constants are dead, one queue (`ms_users_to_ms_studies_user_delete`) has a publisher but no consumer and grows forever, and one (`study-user`) is declared as a durable queue but only ever used as an ignored routing key on a fanout. | see §4 |

---

## 2. Layer overview

### Module sizes (measured)

| Module | Main classes | Test classes | Java LOC | Artifact coords | Java level |
|---|---:|---:|---:|---|---|
| `shanoir-ng-ms-common` | 102 | 1 | 7,691 | `org.shanoir-ng:shanoir-ng-ms-common` (version inherited) | 21 |
| `shanoir-ng-storage` | 4 | 0 | 1,319 | `org.shanoir-ng:shanoir-ng-storage:3.4.0` | 21 |
| `shanoir-ng-anonymization` | 7 | 1 (non-executable) | 1,199 | `org.shanoir.anonymization:anonymization:3.4.0` | 17 |
| `shanoir-ng-study-rights` | 6 | 0 | 746 | `org.shanoir-ng:shanoir-ng-study-rights` (inherited) | 21 |
| `shanoir-ng-exchange` | 6 | 2 | 636 | `org.shanoir-ng:shanoir-ng-exchange:3.4.0` | 17 |
| `shanoir-ng-keycloak-auth` | 2 | 0 | 286 | `org.shanoir-ng:shanoir-ng-keycloak-auth:1.0.0` | 11 |
| **Total** | **127** | **4** | **11,877** | | |

Four different Java source levels (11 / 17 / 17 / 21) and three different versioning schemes across six modules of the same product.

### Dependency graph

```mermaid
graph TD
    subgraph shared["Shared layer (this audit)"]
        MSC["ms-common<br/>7,691 LOC · 1 test"]
        SR["study-rights<br/>746 LOC · 0 tests"]
        ANON["anonymization<br/>1,199 LOC · 0 real tests"]
        EX["exchange<br/>636 LOC · 2 tests"]
        ST["storage<br/>1,319 LOC · 0 tests"]
        KC["keycloak-auth<br/>286 LOC · 0 tests"]
    end

    subgraph services["Runtime services"]
        USERS["ms-users"]
        STUDIES["ms-studies"]
        DATASETS["ms-datasets"]
        IMPORT["ms-import"]
        PRECLIN["ms-preclinical"]
        NIFTI["ms-nifti-conversion"]
        SHUP["ShanoirUploader<br/>(desktop client)"]
        KEYCLOAK["Keycloak 26.2.5<br/>(SPI deployment)"]
    end

    SR --> MSC
    EX --> MSC

    USERS --> MSC
    USERS --> SR
    STUDIES --> MSC
    STUDIES --> ST
    DATASETS --> MSC
    DATASETS --> SR
    DATASETS --> ST
    IMPORT --> MSC
    IMPORT --> SR
    IMPORT --> EX
    IMPORT --> ANON
    PRECLIN --> MSC
    PRECLIN --> ST
    NIFTI --> MSC
    SHUP --> MSC
    SHUP --> EX
    SHUP --> ANON
    KC -.SPI jar.-> KEYCLOAK

    style MSC fill:#ffd9d9
    style SR fill:#ffd9d9
    style ANON fill:#ffd9d9
    style PRECLIN fill:#fff3cd
```

Verified from the poms: `shanoir-ng-ms-common` appears in 10 poms; `shanoir-ng-study-rights` in users/datasets/import; `shanoir-ng-storage` in datasets/preclinical/studies; `shanoir-ng-exchange` in import + shanoir-uploader; `anonymization` only via `shanoir-ng-back/pom.xml`, consumed by ms-import (`ImporterManagerService.java:26`) and ShanoirUploader (`shanoir-uploader/.../dicom/anonymize/Anonymizer.java:9-10`).

**Notable asymmetry:** `shanoir-ng-preclinical` does **not** depend on `study-rights` (0 hits for `StudyRightsService` in that module). Preclinical therefore has no study-level rights enforcement from the shared library, while consuming the same RabbitMQ topology and the shared `SecurityContextUtil.initAuthenticationContext("ADMIN_ROLE")` pattern (`RabbitMQPreclinicalService.java:62,89` — note the string is `"ADMIN_ROLE"`, not `"ROLE_ADMIN"`, so it does not match Spring Security's convention at all).

### Reactor structure

`shanoir-ng-parent/pom.xml` aggregates `keycloak-auth`, `back`, `storage`, `front`, `shanoir-uploader`. `shanoir-ng-back/pom.xml` aggregates the ten backend modules. `storage` is a sibling of `back` but a dependency of three of `back`'s children — the reactor sorts this correctly only because both are built from `shanoir-ng-parent`. Building `shanoir-ng-back` standalone (which is exactly what `maven_repository.yml:33` does) requires `shanoir-ng-storage:3.4.0` to already be installed.

---

## 3. `shanoir-ng-ms-common` deep-dive

### 3.1 Package tree

| Package | Classes | Notable LOC | What it is |
|---|---:|---|---|
| `shared.configuration` | 3 | `RabbitMQConfiguration` 593 | AMQP topology + container factories, Jackson setup, a `RestTemplate` bean |
| `shared.controller` | 2 | | `@ControllerAdvice` exception handler, Swagger redirect |
| `shared.core.model` | 4 | | `AbstractEntity` (`@MappedSuperclass`), `IdName`, `IdList` |
| `shared.core.repository` | 1 | | `ReadOnlyRepository` |
| `shared.dataset` | 2 | | `DatasetModalityType` enum, `RelatedDataset` DTO |
| `shared.dateTime` | 3 | `DateTimeUtils` 108 | date/time conversion; the only tested class |
| `shared.dicom` | 5 | `EquipmentDicom` 145 | DICOM value objects shared import↔studies |
| `shared.dto` | 2 | | `FileEntryDTO`, `StudyExaminationsDTO` |
| `shared.email` | 7 | `EmailStudy` 201 | mail payload DTOs (studies/datasets → users, over AMQP) |
| `shared.error` | 2 | | `FieldError`, `FieldErrorMap extends HashMap` |
| `shared.event` | 3 | `ShanoirEvent` 229 | the platform-wide audit/event model |
| `shared.exception` | 17 | | exception hierarchy + `ErrorModel` |
| `shared.hateoas` | 3 | | `HalEntity`, `Link`, `Links` |
| `shared.jackson` | 2 | | `JacksonUtils` (**test-only**), `LocalDateDeserializer` |
| `shared.message` | 2 | | `CreateCenterForStudyMessage`, `CreateEquipmentForCenterMessage` |
| `shared.paging` | 5 | `PageImpl` 120 | custom `Page` abstraction over Spring Data |
| `shared.quality` | 2 | | `QualityTag`, `SubjectQualityTagDTO` |
| `shared.security` | 7 | `FieldEditionSecurityManagerImpl` 125 | `@EditableOnlyBy`/`@VisibleOnlyBy`, Keycloak service account, `StudyUserRight` |
| `shared.subjectstudy` | 2 | | `SubjectStudyDTO`, `SubjectType` |
| `shared.validation` | 5 | | `@Unique` + `UniqueConstraintManager`, `FindByRepository` |
| `study.rights` (+`.command`) | 3 | | `StudyUserInterface`, `StudyUserCommand`, `CommandType` |
| `utils` | 9 | `Utils` 313, `KeycloakUtil` 200 | grab-bag: zip, sha256, wildcard→regex, MDC filter, static Spring context |
| `utils.assertion` | 6 | `AssertUtils` 158 | **test-only** assertion helpers |
| `utils.mapper` | 2 | | `PageModule`, `PageDeserializer` — **dead** |
| `utils.tests` | 1 | | `TestTrustManager` — **dead, and dangerous** |
| `utils.usermock` | 3 | | spring-security-test `@WithMockKeycloakUser` support |

### 3.2 What should not be in here

Four categories of code sit in `src/main/java` of a library that ships on the production classpath of every microservice:

1. **`utils/tests/TestTrustManager.java:19`** — an `X509TrustManager` whose `checkServerTrusted`/`checkClientTrusted` are empty. Its only reference anywhere in the repo is a *commented-out* line (`shanoir-ng-users/src/test/.../RoleApiControllerITTest.java:40,77`). A trust-everything TrustManager on the production classpath of six services is a liability with zero upside. **Delete it.**
2. **`utils/assertion/AssertUtils.java`** (158 LOC) plus `AccessCheckedFunction{0..4}Arg` — 23 referencing files, **all** under `src/test`. Same for **`shared/jackson/JacksonUtils.java`** (13 referencing files, all tests) which also drags **Joda-Time** onto every service's runtime classpath (`JacksonUtils.java:19`). These belong in a `test-jar` or a separate `shanoir-ng-test-support` artifact.
3. **`utils/usermock/WithMockKeycloakUser`** — a `spring-security-test` `@WithSecurityContext` annotation. It is applied to *production* code at `shanoir-ng-datasets/.../DatasetAcquisitionApiController.java:150`, on a `@RabbitListener` method. **This annotation has no runtime effect outside a Spring test context** — it is processed by `WithSecurityContextTestExecutionListener`. The developer's intent ("this listener runs as ADMIN") is not realised; at runtime the method executes with whatever `SecurityContext` the listener thread happens to hold. See §12.
4. **Genuinely dead code:** `utils/mapper/PageModule.java` + `utils/mapper/PageDeserializer.java` (126 LOC, zero references), `utils/usermock/UserWithId.java` (zero references), `utils/Spring.java` (`Spring.bean(...)` has **zero call sites**; the 21 "references" are the word "Spring" in comments).

### 3.3 Shared entity inventory

`ms-common` itself declares only one persistence artefact:

| Class | Annotation | Implied schema |
|---|---|---|
| `shared/core/model/AbstractEntity.java:28` | `@MappedSuperclass` | `id BIGINT AUTO_INCREMENT PRIMARY KEY` — inherited by **≈70 entities across studies, datasets, users, preclinical** |

`AbstractEntity` has **no `equals`/`hashCode`**. Every entity in the platform therefore uses identity semantics, which is the safe default for Hibernate but means `Set<Entity>` membership silently depends on session identity. The related helper `Utils.equalsIgnoreNull` (`Utils.java:72-83`) *does* compare `AbstractEntity` by id — and dereferences `getId()` without a null check, so it throws `NullPointerException` on transient entities. That helper is used by the field-level security validator (§3.6), so a transient entity in an `@EditableOnlyBy` field produces a 500 instead of a permission decision.

`shanoir-ng-study-rights` declares the one genuinely **shared, replicated** entity:

| Class | Table | Present in DBs |
|---|---|---|
| `StudyUser.java:32-34` | `study_user` (+ `study_user_study_user_rights`, `study_user_center`) | `studies` (master, own class `shanoir-ng-studies/.../study/model/StudyUser.java:50`), `users`, `datasets`, `import` |

The DDL is duplicated per database (`docker-compose/database-migrations/db-changes/users/0005_create_study_user_tables.sql:13-51`, `.../datasets/0015_study_user_center.sql`, `.../import/0002_study_user_center.sql`, `.../studies/0009_study_user_center.sql`) and the seeding migrations perform **cross-database** `INSERT ... SELECT FROM studies.study_user` (`users/0005…sql:44-54`, `datasets/0054_study_users_update.sql:19-27`). See §8.

### 3.4 Shared DTOs and messages

There is no MapStruct mapper in `ms-common` — mapping lives in the services. What `ms-common` owns is the *wire model*:

- **Event:** `ShanoirEvent` (229 LOC) + `ShanoirEventType` (52 constants) + `ShanoirEventService`.
- **Mail:** `EmailBase`, `EmailStudy`, `EmailStudyUsersAdded`, `EmailDatasetsImported`, `EmailDatasetImportFailed`, `StudyInvitationEmail`, `DuaDraftWrapper` — 7 DTOs consumed by ms-users' `RabbitMQUserService` from 6 different queues.
- **DICOM:** `EquipmentDicom`, `InstitutionDicom`, `EchoTime`, `SerieToDatasetsSeparator`, `DicomUtils`.
- **Commands:** `StudyUserCommand` + `CommandType` + `StudyUserInterface`.
- **Cross-service:** `IdName` (101 referencing files — the platform's universal `{id,name}` tuple), `IdList`, `SubjectStudyDTO`, `SubjectQualityTagDTO`, `RelatedDataset`, `StudyExaminationsDTO`, `FileEntryDTO`, `CreateCenterForStudyMessage`, `CreateEquipmentForCenterMessage`.

None of these carry a schema version, a `@JsonTypeInfo` discriminator, or a compatibility test. The only defence against drift is `FAIL_ON_UNKNOWN_PROPERTIES = false` (`JacksonConfiguration.java:50`), which makes additive changes safe and **makes removals and renames silently lossy** — a removed field deserialises to `null` on the consumer side with no error.

`StudyUserCommand.studyUser` is typed as the interface `StudyUserInterface` (`StudyUserCommand.java:22`), which Jackson cannot instantiate. The workaround is the per-message `addAbstractTypeMapping` registration analysed in §5.3.

### 3.5 Exception model

17 exception classes plus `ErrorModel`/`ErrorDetails`. The hierarchy is shallow and inconsistent:

- `ShanoirException` (156 referencing files) is the checked base; `RestServiceException` (137) carries an `ErrorModel`.
- `shared/exception/SecurityException.java` **shadows `java.lang.SecurityException`**. `KeycloakUtil.getJwtAuthenticationToken()` declares `throws SecurityException` and throws `new SecurityException("Anonymous user")` (`KeycloakUtil.java:163-169`) — but `KeycloakUtil` does not import the Shanoir one, so this is the unchecked JDK class. `KeycloakServiceAccountUtils` imports the Shanoir one (`KeycloakServiceAccountUtils.java:20`). Two classes with the same simple name in the same layer, resolved differently per file.
- `shared/exception/AccessDeniedException.java` similarly shadows `org.springframework.security.access.AccessDeniedException`. **`GlobalExceptionHandler` only handles the Spring one** (`GlobalExceptionHandler.java:26,46`). Throwing the Shanoir `AccessDeniedException` therefore falls through to the generic `Exception` handler and returns **HTTP 500 instead of 403** (`GlobalExceptionHandler.java:59-69`).
- The generic handler puts `e.getMessage()` straight into the response body (`GlobalExceptionHandler.java:65`). Hibernate/JDBC messages contain SQL fragments, column names and sometimes values; `StorageException` messages contain absolute filesystem paths (`FileSystemStorageService.java:263`). This is an information-disclosure channel to any authenticated user.
- `handleRestServiceException` calls `HttpStatus.valueOf(e.getErrorModel().getCode())` (`GlobalExceptionHandler.java:44`). A non-HTTP code or a null code throws *inside the handler*.

### 3.6 Security helpers

**`KeycloakUtil`** (200 LOC, 66 referencing files) — static accessors over `SecurityContextHolder`.

- `getJwtAuthenticationToken()` blind-casts `getAuthentication()` to `JwtAuthenticationToken` (`KeycloakUtil.java:168`). Any other `Authentication` implementation → `ClassCastException`.
- `canImportFromPACS()` (`:78-81`) has no null guard on `jwt` and dereferences `getClaims().get("canImportFromPACS").toString()` — **NPE if the claim is absent**, which is the default for a realm that has not been configured with that mapper.
- `getConnectedUserRoles()` returns an **empty list** for anonymous users (`:87-89`) rather than throwing. Combined with `Utils.haveOneInCommon` in the field-security validator, "no roles" reads as "no matching role" — fail-closed there, but the pattern is a footgun for any caller that treats empty as "unknown".
- `getTokenUserId()` returns `null` when the `userId` claim is missing (`:117`). Callers vary: `StudyRightsService` throws `IllegalStateException`; `getUserRights()` passes the null straight to the repository (`StudyRightsService.java:184-187`).

**`SecurityContextUtil`** (106 LOC) — this is the most consequential class in the module.

```java
// shanoir-ng-ms-common/src/main/java/org/shanoir/ng/utils/SecurityContextUtil.java:50-52
public static void initAuthenticationContext(String role) {
    initAuthenticationContext(role, 92233720L, "mock-token-value");
}
```

It **fabricates a JWT** (`:100-105`) with a synthetic `userId` of `92233720` and installs it in the `SecurityContextHolder`. It is invoked **43 times**, almost entirely from `@RabbitListener` methods across studies (9), datasets (7), users (7), preclinical (2), study-rights consumers, and schedulers. Three problems:

1. It converts "can publish to a queue" into "is a platform administrator". There is no per-queue authorization in RabbitMQ here (§4.6).
2. **The context is never cleared.** `clearAuthentication()` exists (`:41-43`) but has exactly **one** call site in the whole repository (`shanoir-ng-users/.../ScheduledTasks.java:89`). Listener containers reuse threads (`RabbitMQConfiguration.java:45-46` allows 10–100 concurrent consumers), so a fabricated ADMIN context persists on the thread and is visible to the *next* message handled by it — including handlers that deliberately did not elevate.
3. `decodeJwtClaims` (`:81-91`) base64-decodes the JWT payload **without verifying the signature** and returns the claims. `getClientId(token)` feeds the result into `KeycloakServiceAccountUtils.refreshUserToken`'s `client_id` parameter (`KeycloakServiceAccountUtils.java:70`). It also allocates a fresh `ObjectMapper` per call and swallows all exceptions into `Map.of()`, so a malformed token yields `client_id = null`.

**`KeycloakServiceAccountUtils`** — quoted default values:

```java
// KeycloakServiceAccountUtils.java:47-52
@Value("${service-account.token.uri:'https://shanoir-ng-nginx/auth'}")   private String serverUrl;
@Value("${service-account.client.id:'service-account'}")                 private String clientId;
@Value("${service-account.client.credential-secret:'SECRET'}")           private String clientSecret;
```

Spring does not strip the single quotes: unset properties yield the literal `'https://shanoir-ng-nginx/auth'` (not a valid URL) and the literal client secret `'SECRET'`. `shanoir-ng-datasets/src/main/resources/application.yml:183-189` overrides all three correctly; `shanoir-ng-users/src/main/resources/application.yml:117-119` defines only `service-account.user.*`, so in ms-users this `@Component` is wired with the hardcoded fallbacks.

**`FieldEditionSecurityManagerImpl`** — reflection-driven `@EditableOnlyBy` enforcement.

- `validate` does `repository.findById(...).orElse(null)` then `validateUpdate(entity, originalEntity)`, which immediately calls `originalEntity.getClass()` (`FieldEditionSecurityManagerImpl.java:49-59`). Updating a non-existent id ⇒ NPE ⇒ 500.
- Change detection uses `Utils.equalsIgnoreNull`, which for `AbstractEntity` operands compares **only the id** (`Utils.java:78-80`). A protected field whose type is an entity is therefore considered unmodified whenever the id is unchanged, even if its contents were replaced.
- Missing getters throw `IllegalStateException` at runtime (`:80-85`). With zero tests, that is discovered in production.

**`MDCFilter`** — `MDC.put("username", "Admin")` for every request without a `JwtAuthenticationToken` (`MDCFilter.java:31`). Unauthenticated traffic is logged under the label `Admin`. For a platform whose audit trail matters, this actively corrupts the log record.

### 3.7 Dead code found by cross-repo usage search

| Path | External refs (main) | Verdict |
|---|---:|---|
| `utils/mapper/PageModule.java` | 0 | dead |
| `utils/mapper/PageDeserializer.java` | 1 (only `PageModule`) | dead |
| `utils/usermock/UserWithId.java` | 0 | dead |
| `utils/tests/TestTrustManager.java` | 0 (1 commented-out) | dead + dangerous |
| `utils/Spring.java` | 0 (`Spring.bean` never called) | dead |
| `shared/jackson/JacksonUtils.java` | 0 main / 13 test | wrong source set |
| `utils/assertion/*` (6 files, ~238 LOC) | 0 main / 23 test | wrong source set |
| `shared/security/ControllerSecurityService.java` | 0 main / 8 test | referenced only from `@WebMvcTest` wiring; verify SpEL usage before deleting *(inferred)* |
| `shared/paging/FacetPageableImpl.java` | 1 | near-dead |
| `utils/ListDependencyUpdate.java` | 1 | near-dead |

Roughly **500 LOC of provably dead code** and another **~400 LOC of test-only code** in the production source set.

---

## 4. The RabbitMQ topology, definitively

### 4.1 How everything is declared

`RabbitMQConfiguration` (`shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/configuration/RabbitMQConfiguration.java`) declares:

- **67 `public static final String` constants** — 65 queue names, 2 exchange names.
- **64 `Queue` beans**, all via `new Queue(NAME, true)` (`Queue(String, boolean durable)`), i.e. **durable = true, exclusive = false, autoDelete = false, arguments = null** for every single queue. No `x-dead-letter-exchange`, no `x-message-ttl`, no `x-max-length`, no `x-queue-type` (all classic queues).
- **2 exchange beans**: `FanoutExchange(STUDY_USER_EXCHANGE, true, false)` (`:394-396`) and `TopicExchange(EVENTS_EXCHANGE)` (`:588-591`, single-arg ⇒ durable, non-auto-delete).
- **2 listener container factories**: `multipleConsumersFactory` (concurrency 10, max 100, prefetch 1, `:41-52`) and `singleConsumerFactory` (concurrency 1, **prefetch left at the Spring default of 250**, `:54-60`).
- The whole class is annotated `@Profile("!test")` (`:35`), so the topology and both container factories are **absent from every test context**. This is why no contract test for the topology can exist today.

63 of the 64 queue beans are `public static Queue` methods; `subjectBatchUpdateQueue()` (`:563-566`) is the lone non-static one — cosmetic inconsistency.

The class javadoc claims it declares "all queues" (`:27-29`). It does not: `shanoir-ng-datasets/.../bids/service/BidsValidationConfiguration.java:24-36` declares two more (`bids.validate`, `bids.validated`) with `QueueBuilder.durable(...)`, outside the central registry.

### 4.2 Complete inventory

Legend — **Sync** = used with `convertSendAndReceive` (RPC); **Async** = `convertAndSend`. All queues are durable / non-exclusive / non-auto-delete / no arguments unless noted. "CF" = container factory (`multi` = `multipleConsumersFactory`, `single` = `singleConsumerFactory`, `default` = none specified).

| # | Queue name | Constant | Declared at | Publisher(s) | Consumer(s) | CF | Payload | Mode | Notes |
|---:|---|---|---|---|---|---|---|---|---|
| 1 | `acquisition-equipment-center-queue` | `ACQUISITION_EQUIPMENT_CENTER_QUEUE` | RMQC:264 | *(none found)* | studies `RabbitMqCenterService:48` | multi | String | Sync | **No publisher — dead consumer** |
| 2 | `acquisition-equipment-code-queue` | `ACQUISITION_EQUIPMENT_CODE_QUEUE` | RMQC:268 | datasets `BidsImporterService:214` | studies `RabbitMqCenterService:64` | multi | String | Sync | |
| 3 | `acquisition-equipment-create-queue` | `ACQUISITION_EQUIPMENT_CREATE_QUEUE` | RMQC:273 | datasets `DicomImporterService:421` | studies `RabbitMQStudiesService:334` | single | JSON `CreateEquipmentForCenterMessage` | Sync | |
| 4 | `acquisition-equipment-update-queue` | `ACQUISITION_EQUIPMENT_UPDATE_QUEUE` | RMQC:278 | studies ×3 (`AcquisitionEquipmentServiceImpl:120`, `ManufacturerServiceImpl:92`, `ManufacturerModelServiceImpl:135`) | datasets `RabbitMQDatasetsService:268` | single | JSON | Async | |
| 5 | `anima-conversion-queue` | `ANIMA_CONVERSION_QUEUE` | RMQC:283 | import `ImporterApiController:486` | nifti `RabbitMqNiftiConversionService:69` | single | String | Sync | Reply cast to `boolean` → NPE on timeout |
| 6 | `bids-event-queue` | `BIDS_EVENT_QUEUE` | RMQC:288 | — | — | — | — | — | **DEAD constant + live durable queue** |
| 7 | `bruker-conversion-queue` | `BRUKER_CONVERSION_QUEUE` | RMQC:293 | preclinical `BrukerApiController:139` | nifti `RabbitMqNiftiConversionService:49` | multi | String | Sync | Reply cast to `boolean` |
| 8 | `center-create-queue` | `CENTER_CREATE_QUEUE` | RMQC:298 | datasets `DicomImporterService:478` | studies `RabbitMQStudiesService:301` | single | JSON `CreateCenterForStudyMessage` | Sync | |
| 9 | `center-delete-queue` | `CENTER_DELETE_QUEUE` | RMQC:303 | studies `CenterServiceImpl:190` | datasets `RabbitMQDatasetsService:286` | single | **`Long`** | Async | Java-serialized payload — see §4.5 |
| 10 | `center-update-queue` | `CENTER_UPDATE_QUEUE` | RMQC:308 | studies `CenterServiceImpl:181` | datasets `RabbitMQDatasetsService:274` | single | JSON | Async | |
| 11 | `copy-datasets-to-study-queue` | `COPY_DATASETS_TO_STUDY_QUEUE` | RMQC:313 | studies `RelatedDatasetServiceImpl:271` | datasets `RabbitMQDatasetsService:449` | multi | JSON | Async | Handler is `@Async` — ack before work completes |
| 12 | `create-dataset-acquisition-queue` | `CREATE_DATASET_ACQUISITION_QUEUE` | RMQC:318 | — | — | — | — | — | **DEAD** |
| 13 | `dataset-subjects-queue` | `DATASET_SUBJECT_QUEUE` | RMQC:323 | *(none)* | studies `RabbitMQSubjectService:67` | multi | String | Sync | **No publisher** |
| 14 | `dataset-subject-study-queue` | `DATASET_SUBJECT_STUDY_QUEUE` | RMQC:328 | *(none)* | studies `RabbitMQSubjectService:84` | multi | JSON `IdName` | Sync | **No publisher** |
| 15 | `delete-animal-subject-queue` | `DELETE_ANIMAL_SUBJECT_QUEUE` | RMQC:333 | studies `SubjectServiceImpl:135` | preclinical `RabbitMQPreclinicalService:59` | **default** | String | Async | Only queue using the auto-configured default factory |
| 16 | `copy-animal-subject-queue` | `COPY_ANIMAL_SUBJECT_QUEUE` | RMQC:338 | studies `RelatedDatasetServiceImpl:219` | preclinical `RabbitMQPreclinicalService:86` | **default** | JSON | Async | |
| 17 | `delete-study-queue` | `DELETE_STUDY_QUEUE` | RMQC:348 | via `events-exchange`, key `deleteStudy.event` | datasets `RabbitMQDatasetsService:373` | single | JSON `ShanoirEvent` | Async | **Declared twice** (bean + `@QueueBinding`) |
| 18 | `delete-subject-queue` | `DELETE_SUBJECT_QUEUE` | RMQC:343 | studies `SubjectServiceImpl:139` | datasets `RabbitMQDatasetsService:329` | single | String | Async | |
| 19 | `delete-user-queue` | `DELETE_USER_QUEUE` | RMQC:353 | users `UserServiceImpl:151` | studies `StudyUserServiceImpl:105` | single | JSON `ShanoirEvent` | Async | |
| 20 | `dua-draft-mail-queue` | `DUA_DRAFT_MAIL_QUEUE` | RMQC:358 | studies `DuaDraftAPIController:121` | users `RabbitMQUserService:167` | multi | JSON `DuaDraftWrapper` | Async | |
| 21 | `equipment-from-code-queue` | `EQUIPMENT_FROM_CODE_QUEUE` | RMQC:363 | import `ImporterApiController:867` | studies `RabbitMqCenterService:82` | multi | String | Sync | |
| 22 | `execution-monitoring-task` | `EXECUTION_MONITORING_TASK` | RMQC:368 | datasets `ExecutionMonitoringResumptionRunner:87` | users `RabbitMQEventService:47` | multi | **`Long`** | Sync | Java-serialized |
| 23 | `examination-creation-queue` | `EXAMINATION_CREATION_QUEUE` | RMQC:373 | import ×3 (`ImporterApiController:897`, `BidsImporterApiController:184,214`) | datasets `RabbitMqExaminationService:55` | multi | JSON `Examination` | Sync | |
| 24 | `examination-extra-data-queue` | `EXAMINATION_EXTRA_DATA_QUEUE` | RMQC:378 | import `BidsImporterApiController:254` | datasets `RabbitMqExaminationService:74` | multi | JSON `IdName` | Async | |
| 25 | `examination-study-queue` | `EXAMINATION_STUDY_QUEUE` | RMQC:383 | via `events-exchange`, key `createExamination.event` | studies `RabbitMQStudiesService:112` | *(binding)* | JSON `ShanoirEvent` | Async | **Declared twice** |
| 26 | `examination-studies-queue` | `EXAMINATION_STUDIES_QUEUE` | **no bean** | via `events-exchange`, key `createExaminations.event` | studies `RabbitMQStudiesService:159` | *(binding)* | JSON | Async | **Only queue constant with no central bean** |
| 27 | `examination-study-delete-queue` | `EXAMINATION_STUDY_DELETE_QUEUE` | RMQC:388 | datasets `ExaminationServiceImpl:171` | studies `RabbitMQStudiesService:191` | single | JSON `ShanoirEvent` | Async | |
| 28 | `find-study-card-queue` | `FIND_STUDY_CARD_QUEUE` | RMQC:399 | *(none)* | datasets `RabbitMqStudyCardService:45` | multi | String | Sync | **No publisher** |
| 29 | `importer-bids-dataset-queue` | `IMPORTER_BIDS_DATASET_QUEUE` | RMQC:418 | import `BidsImporterApiController:250` | datasets `BidsImporterService:104` | multi | JSON `ImportJob` | Async | |
| 30 | `importer-queue-dataset` | `IMPORTER_QUEUE_DATASET` | RMQC:438 | import `ImporterManagerService:181` | datasets `DatasetAcquisitionApiController:147` | multi | JSON `ImportJob` | Async | Consumer carries the no-op `@WithMockKeycloakUser` (§12) |
| 31 | `import-dataset-failed-mail-queue` | `IMPORT_DATASET_FAILED_MAIL_QUEUE` | RMQC:423 | import `ImporterManagerService:273`, datasets `ImporterMailService:130` | users `RabbitMQUserService:106` | multi | JSON `EmailDatasetImportFailed` | Async | |
| 32 | `import-dataset-mail-queue` | `IMPORT_DATASET_MAIL_QUEUE` | RMQC:428 | datasets `ImporterMailService:130` | users `RabbitMQUserService:88` | multi | JSON `EmailDatasetsImported` | Async | |
| 33 | `import-eeg-queue` | `IMPORT_EEG_QUEUE` | RMQC:433 | import `ImporterApiController:705` | datasets `DatasetAcquisitionApiController:133` | multi | JSON `EegImportJob` | Sync | Reply cast to `Integer` |
| 34 | `import-study-card-queue` | `IMPORT_STUDY_CARD_QUEUE` | RMQC:443 | import `ImporterApiController:874` | datasets `RabbitMqStudyCardService:56` | multi | JSON `Properties` | Sync | |
| 35 | `ms_users_to_ms_studies_user_delete` | `MS_USERS_TO_MS_STUDIES_USER_DELETE` | RMQC:403 | users `InterMicroservicesCommunicator:49` | **none** | — | `Long` | Async | **Publisher with no consumer — grows without bound** |
| 36 | `nifti-conversion-queue` | `NIFTI_CONVERSION_QUEUE` | RMQC:448 | datasets `DatasetDownloaderServiceImpl:316`, `BIDSServiceImpl:444` | nifti `RabbitMqNiftiConversionService:85` | multi | String | Sync | |
| 37 | `reload-bids-queue` | `RELOAD_BIDS` | RMQC:453 | datasets ×6 | datasets `BIDSServiceImpl:160` | **default** | JSON `Long` | Async | Datasets → datasets: an in-process call routed via the broker |
| 38 | `shanoir-events-queue` | `SHANOIR_EVENTS_QUEUE` | RMQC:408 | `ShanoirEventService:60` via `events-exchange` key `*.event` | users `RabbitMQUserService:67` | single | JSON `ShanoirEvent` | Async | **Declared twice**; the platform audit trail |
| 39 | `shanoir-events-queue-import` | `SHANOIR_EVENTS_QUEUE_IMPORT` | RMQC:413 | — | — | — | — | — | **DEAD** |
| 40 | `study-admin-queue` | `STUDY_ADMINS_QUEUE` | RMQC:463 | users `EmailServiceImpl:647` | study-rights `RabbitMqStudyUserService:82` | multi | **`Long`** → **`List<Long>`** | Sync | Java-serialized both ways; returns `null` when empty |
| 41 | `study-anonymisation-profile-queue` | `STUDY_ANONYMISATION_PROFILE_QUEUE` | RMQC:468 | import `ImporterApiController:905` | studies `RabbitMQStudiesService:218` | single | **`Long`** → String | Sync | Determines the anonymization profile — see §6 |
| 42 | `study-center-queue` | `STUDY_CENTER_QUEUE` | RMQC:473 | — | — | — | — | — | **DEAD** |
| 43 | `study-dataset-type` | `STUDY_DATASET_TYPE` | RMQC:488 | — | — | — | — | — | **DEAD** |
| 44 | `study-datasets-detailed-storage-volume` | `STUDY_DATASETS_DETAILED_STORAGE_VOLUME` | RMQC:478 | studies `StudyServiceImpl:970` | datasets `RabbitMQDatasetsService:407` | multi | **`Long`** | Sync | |
| 45 | `study-datasets-total-storage-volume` | `STUDY_DATASETS_TOTAL_STORAGE_VOLUME` | RMQC:483 | studies `StudyServiceImpl:992` | datasets `RabbitMQDatasetsService:422` | multi | **`List<Long>`** | Sync | Java-serialized collection |
| 46 | `study-i-can-admin` | `STUDY_I_CAN_ADMIN_QUEUE` | RMQC:493 | users `AccessRequestApiController:153` | study-rights `RabbitMqStudyUserService:70` | multi | **`Long`** → **`List<Long>`** | Sync | Authorization data over Java serialization |
| 47 | `study-invitation-queue` | `STUDY_INVITATION_QUEUE` | RMQC:498 | — | — | — | — | — | **DEAD** (`StudyInvitationEmail` DTO exists) |
| 48 | `study-name-queue` | `STUDY_NAME_QUEUE` | RMQC:503 | users ×3 | studies `RabbitMQStudiesService:207` | single | **`Long`** | Sync | Consumer does `studyRepo.findById(id).get()` → `NoSuchElementException` |
| 49 | `study-update-queue` | `STUDY_UPDATE_QUEUE` | RMQC:508 | studies `StudyServiceImpl:895` | datasets `RabbitMQDatasetsService:161` | single | JSON `Study` | Sync | |
| 50 | `study-draft-state-queue` | `STUDY_DRAFT_STATE_QUEUE` | RMQC:513 | import `ImportSecurityService:84` | studies `RabbitMQStudiesService:385` | single | String | Sync | Used in an authorization decision |
| 51 | `study-subscription-queue` | `STUDY_SUBSCRIPTION_QUEUE` | RMQC:518 | users `AccessRequestApiController:201` | studies `RabbitMQStudiesService:233` | single | JSON `ShanoirEvent` | Sync | Reply ignored |
| 52 | `studies-subject-study-study-card-tag` | `STUDIES_SUBJECT_STUDY_STUDY_CARD_TAG` | RMQC:458 | datasets `SubjectService:107` | studies `RabbitMQStudiesService:276` | single | JSON `List<SubjectQualityTagDTO>` | Async | |
| 53 | `study-participants-tsv` | `STUDY_PARTICIPANTS_TSV` | RMQC:548 | datasets `BIDSServiceImpl:221` | studies `RabbitMQStudiesService:363` | single | JSON | Sync | Publisher sends JSON String, consumer signature is `Long` — **type mismatch** |
| 54 | `study-user-mail-queue` | `STUDY_USER_MAIL_QUEUE` | RMQC:528 | studies `StudyServiceImpl:785` | users `RabbitMQUserService:124` | multi | JSON `EmailStudyUsersAdded` | Async | |
| 55 | `draft-study-mail-queue` | `DRAFT_STUDY_MAIL_QUEUE` | RMQC:533 | studies `StudyServiceImpl:798` | users `RabbitMQUserService:137` | multi | JSON `EmailStudy` | Async | |
| 56 | `approve-study-mail-queue` | `APPROVE_STUDY_MAIL_QUEUE` | RMQC:538 | studies `StudyServiceImpl:815` | users `RabbitMQUserService:150` | multi | JSON `EmailStudy` | Async | |
| 57 | `study-user` | `STUDY_USER_QUEUE` | RMQC:543 | used only as a **routing key** on the fanout (`StudyUserUpdateBroadcastService:44`) | **none** | — | — | — | Durable queue that is never bound and never read; the routing key is ignored by a fanout exchange |
| 58 | `study-user-queue-dataset` | `STUDY_USER_QUEUE_DATASET` | RMQC:523 | fanout `study-user-exchange` | datasets `RabbitMQDatasetsService:152` | **multi** | JSON `StudyUserCommand[]` | Async | **Declared twice**; concurrency 10 destroys command ordering (§5.4) |
| 59 | `study-user-queue-import` | `STUDY_USER_QUEUE_IMPORT` | RMQC:553 | fanout | import `RabbitMQImportService:36` | **multi** | JSON `StudyUserCommand[]` | Async | **Declared twice**; same ordering issue |
| 60 | `study-user-queue-users` | `STUDY_USER_QUEUE_USERS` | RMQC:558 | fanout | users `RabbitMQUserService:54` | **multi** | JSON `StudyUserCommand[]` | Async | **Declared twice**; same ordering issue |
| 61 | `subject_batch_update_queue` | `SUBJECT_BATCH_UPDATE_QUEUE` | RMQC:563 | studies `SubjectServiceImpl:463` | datasets `RabbitMQDatasetsService:231` | single | JSON | Sync | Only non-static queue bean; snake_case name breaks the kebab-case convention |
| 62 | `subject-update-queue` | `SUBJECT_UPDATE_QUEUE` | RMQC:568 | studies `SubjectServiceImpl:445` | datasets `RabbitMQDatasetsService:186` | single | JSON | Sync | |
| 63 | `subjects-name-queue` | `SUBJECTS_NAME_QUEUE` | RMQC:573 | preclinical `AnimalSubjectServiceImpl:150` | studies `RabbitMQSubjectService:121` | multi | JSON `IdName` | Sync | Reply cast to `boolean` → NPE on timeout |
| 64 | `subjects-queue-with-datasets` | `SUBJECTS_QUEUE_WITH_DATASETS` | RMQC:578 | import ×2, preclinical `AnimalSubjectServiceImpl:155` | studies `RabbitMQSubjectService:135` | multi | JSON `Subject` | Sync | |
| 65 | `subjects-queue-without-datasets` | `SUBJECTS_QUEUE_WITHOUT_DATASETS` | RMQC:583 | datasets `DicomImporterService:565` | studies `RabbitMQSubjectService:149` | multi | JSON `Subject` | Sync | |
| — | `bids.validate` | `BidsValidationConfiguration.BIDS_VALIDATION_REQUEST_QUEUE` | datasets `BidsValidationConfiguration:29-31` | datasets `BidsValidationPublisher:39,48` | external `bids-validator` container | — | String path | Async | **Declared outside `ms-common`** |
| — | `bids.validated` | `BidsValidationConfiguration.BIDS_VALIDATION_RESULT_QUEUE` | datasets `BidsValidationConfiguration:34-36` | external | datasets `BidsValidationResultListener:29` | default | JSON | Async | Correlation-id based reply; the only place doing that |

**Exchanges**

| Name | Constant | Type | Declared | Properties | Bindings | Notes |
|---|---|---|---|---|---|---|
| `events-exchange` | `EVENTS_EXCHANGE` | topic | `RabbitMQConfiguration:588-591` **and** `@Exchange(...)` in datasets `RabbitMQDatasetsService:376`, studies `RabbitMQStudiesService:116,164`, users `RabbitMQUserService:70` | durable, not auto-delete | `*.event` → `shanoir-events-queue`; `deleteStudy.event` → `delete-study-queue`; `createExamination.event` → `examination-study-queue`; `createExaminations.event` → `examination-studies-queue` | All 52 `ShanoirEventType` constants match `*.event`, so no event is silently unroutable today — but nothing enforces that invariant |
| `study-user-exchange` | `STUDY_USER_EXCHANGE` | fanout | `RabbitMQConfiguration:393-396` **and** `@Exchange(type=FANOUT)` in datasets:154, import:38, users:56 | durable, not auto-delete | 3 queues (dataset/import/users) | The rights-replication bus. `ignoreDeclarationExceptions="true"` everywhere masks any property mismatch between the two declaration sites |

### 4.3 Counts

- 65 queue-name constants; 64 central `Queue` beans; **6 constants with no publisher and no consumer** (`bids-event-queue`, `create-dataset-acquisition-queue`, `shanoir-events-queue-import`, `study-center-queue`, `study-dataset-type`, `study-invitation-queue`).
- **4 queues with a consumer but no publisher** (`acquisition-equipment-center-queue`, `dataset-subjects-queue`, `dataset-subject-study-queue`, `find-study-card-queue`) — RPC endpoints nobody calls.
- **1 queue with a publisher but no consumer** (`ms_users_to_ms_studies_user_delete`) — durable, unbounded growth.
- **1 queue never bound and never read** (`study-user`).
- **6 queues declared in two places** (`delete-study-queue`, `examination-study-queue`, `shanoir-events-queue`, `study-user-queue-{dataset,import,users}`).
- **1 queue constant with no central bean** (`examination-studies-queue`).
- **2 queues declared entirely outside the "centralised" configuration** (`bids.validate`, `bids.validated`).
- **0 dead-letter queues. 0 TTLs. 0 retry policies. 0 alternate exchanges. 0 quorum queues.**

### 4.4 RPC and timeouts

30 of the 65 queues are used with `convertSendAndReceive` — synchronous request/reply over AMQP, i.e. temporary reply queues and blocking HTTP threads. Only **ms-studies** configures a reply timeout:

```yaml
# shanoir-ng-studies/src/main/resources/application.yml:76-77
    template:
      reply-timeout: 60000
```

Every other service uses Spring AMQP's default of **5,000 ms**. On timeout `convertSendAndReceive` returns `null` — silently. Callers that unbox the result crash:

- `shanoir-ng-preclinical/.../AnimalSubjectServiceImpl.java:150` — `return (boolean) rabbitTemplate.convertSendAndReceive(SUBJECTS_NAME_QUEUE, request);`
- `shanoir-ng-preclinical/.../BrukerApiController.java:139` — same pattern
- `shanoir-ng-import/.../ImporterApiController.java:486` — `boolean result = (boolean) …ANIMA_CONVERSION_QUEUE…` (a conversion job that will routinely exceed 5 s)
- `shanoir-ng-datasets/.../BIDSServiceImpl.java:444` — same

Each is a `NullPointerException` on unboxing whenever the downstream service is slow. `DatasetDownloaderServiceImpl.java:316` shows the correct idiom (`Boolean.TRUE.equals(...)`) — it just is not applied consistently.

There is also an outright contract mismatch: `study-participants-tsv` is published as a JSON string (`BIDSServiceImpl.java:221` — `objectMapper.writeValueAsString(studyId)`) but the listener signature is `String studyParticipantsTsv(Long studyId)` (`RabbitMQStudiesService.java:365`). *(Inferred: this is likely a live `ListenerExecutionFailedException`, but I did not run it.)*

### 4.5 Message converter — unsafe deserialization

**There is no `MessageConverter` bean anywhere in the repository** (grep for `MessageConverter`, `Jackson2JsonMessageConverter`, `setMessageConverter`, `allowedListPatterns` returns zero hits outside imports). Every `RabbitTemplate` and every listener container therefore uses Spring Boot's auto-configured **`SimpleMessageConverter`**.

`SimpleMessageConverter` handles `String` and `byte[]` as text/bytes, but for any other `Serializable` object it uses **Java serialization** with content type `application/x-java-serialized-object` — and on the receiving side it deserializes such bodies. Its allow-list (`allowedListPatterns`) is **not configured**, which means no class restriction.

The queues that carry non-String payloads are exactly the ones above marked "Java-serialized": `center-delete-queue` (`Long`), `execution-monitoring-task` (`Long`), `study-admin-queue` (`Long` → `List<Long>`), `study-anonymisation-profile-queue` (`Long`), `study-datasets-detailed-storage-volume` (`Long`), `study-datasets-total-storage-volume` (`List<Long>`), `study-i-can-admin` (`Long` → `List<Long>`), `study-name-queue` (`Long`). Replies of type `Long`, `List<Long>` and `boolean` travel the same way.

Consequence: an actor able to publish to any of those queues — or to plant a reply on an RPC reply queue — can deliver an arbitrary Java-serialized object graph to a JVM whose classpath includes Spring, Hibernate, Jackson, dcm4che, Apache POI and the AWS SDK. That is a textbook gadget-chain surface. Combined with §4.6 this is the report's top finding.

**Fix:** register a `Jackson2JsonMessageConverter` globally, or at minimum call `setAllowedListPatterns(List.of("java.lang.*", "java.util.*"))` on a `SimpleMessageConverter` bean, and convert the `Long`/`List<Long>` payloads to JSON strings like the rest of the platform already does.

### 4.6 Broker exposure

```yaml
# docker-compose.yml:74-83  (identical in docker-compose-dev.yml:79-88)
  rabbitmq:
    image: rabbitmq:3.10.7
    ports:
     - "5672:5672"
     - "15672:15672"
```

- **`rabbitmq:3.10.7` is end-of-life** (the 3.10 series stopped receiving fixes in 2023).
- Both AMQP and the management UI are **published to the host on all interfaces**, not merely `expose`d on the Docker network.
- Credentials are `guest`/`guest`, hardcoded in `shanoir-ng-studies/src/main/resources/application.yml:74-75`, `shanoir-ng-nifti-conversion/src/main/resources/application.yml:31-32`, and `docker-compose.yml:460` (`AMQP_URL=amqp://guest:guest@rabbitmq:5672/`). The official RabbitMQ image ships `loopback_users.guest = false`, so `guest` is usable from any address *(inferred from the image's documented default configuration; not verified against a running container)*.
- No vhost separation, no per-service users, no per-queue permissions.

Chain the three sections: reach `:5672` → authenticate as `guest` → publish a `StudyUserCommand[]` granting yourself `CAN_ADMINISTRATE` on every study, or publish onto `importer-queue-dataset`, whose handler elevates to `ROLE_ADMIN`, or deliver a Java-serialized gadget to `study-i-can-admin`. Nothing in the shared layer stands in the way.

### 4.7 Messaging architecture assessment

**Reliability.** Publishing is fire-and-forget: no `publisher-confirm-type`, no `publisher-returns`, no `mandatory` flag. An unroutable message is dropped by the broker with no signal. `ShanoirEventService.publishEvent` catches only `JsonProcessingException` (`ShanoirEventService.java:61-64`), so an `AmqpException` propagates to the caller — which is arguably better than swallowing it, but it means the audit event and the business transaction fail together with no compensation.

**Error handling and poison messages.** The prevailing idiom is `try { … } catch (Exception e) { LOG.error(…) }` inside the listener, which acks the message and loses it. Where the code *does* signal failure it throws `AmqpRejectAndDontRequeueException` (`RabbitMqStudyUserService.java:66`, `StudyUserServiceImpl.java:109`, `RabbitMQUserService.java:73`), which with no DLQ configured means **the message is discarded permanently**. There is no third option: every failure path is either "pretend it worked" or "throw it away". `RabbitMQDatasetsService.java:197-205` contains a revealing comment about splitting `@Transactional` and `@RabbitListener` "to avoid endless loops rabbitmq re-sending the same message" — a poison-message loop that was worked around rather than fixed with a DLQ.

**Ordering.** The three rights-replication queues use `multipleConsumersFactory` (10 concurrent consumers, prefetch 1). Command batches are therefore processed **concurrently and out of order**. A `DELETE` (revoke) can be applied before an earlier `CREATE`/`UPDATE` for the same `study_user` id, leaving the replica with rights that were revoked. This is the single most dangerous ordering assumption in the system, and it is on the authorization path.

**Idempotency.** No message carries an id, sequence number or version. `StudyUserUpdateService.processCommands` is *accidentally* idempotent for `UPDATE` and `DELETE` (last-write-wins / no-op), but `CREATE` re-executes `saveAll` on an assigned-id entity, which merges — so redelivery is survivable but reordering is not.

**Observability.** `spring.rabbitmq` blocks configure only host/port/credentials. No metrics, no tracing, no correlation id propagated from HTTP into AMQP (the `MDCFilter` sets an MDC username for servlet requests only, and listener threads have none). A cross-service import failure cannot be reconstructed from logs.

**Testability.** `@Profile("!test")` on `RabbitMQConfiguration` (`:35`) removes the entire topology *and the container factories* from test contexts. There is therefore no way to assert, in a test, that a queue name constant matches its consumers, that a payload round-trips, or that the exchange bindings are right.

---

## 5. `shanoir-ng-study-rights` deep-dive

746 LOC, 6 classes, **0 tests**. This is the module that answers "may this user see this study?" for `ms-datasets` and `ms-import`.

### 5.1 How it works

It is **not** a client of ms-studies. It is a **read-replica pattern**:

1. ms-studies is the master. On any change it builds `StudyUserCommand`s and publishes the JSON array to the `study-user-exchange` fanout (`shanoir-ng-studies/.../StudyUserUpdateBroadcastService.java:41-47`).
2. Each consuming service has its own copy of the `study_user` / `study_user_study_user_rights` / `study_user_center` tables and applies the commands via `StudyUserUpdateService.processCommands` (`StudyUserUpdateService.java:38-92`).
3. Authorization checks are plain JPA reads against that local copy (`StudyRightsService.java:48`, `:68`, `:122`, `:143`, `:166`, `:178`).

Consumers: `shanoir-ng-datasets/.../DatasetSecurityService.java` (37 references — the main consumer), `DatasetServiceImpl.java`, `ExecutionMonitoringSecurityService.java`, `shanoir-ng-import/.../ImportSecurityService.java`, and `shanoir-ng-users/.../ShanoirUsersManagement.java`. **`ms-preclinical` does not use it at all.**

### 5.2 Caching and consistency model

There is **no in-process cache**. `UserRights` is constructed fresh from a repository query on every call (`StudyRightsService.java:177-187`), and `DatasetSecurityService` calls `getUserRights()` per authorization decision (e.g. `:417`, `:449`, `:717`). Good: no cache-invalidation bugs, no unbounded cache. Bad: an N-row `study_user` query plus an `@ElementCollection` fetch on every request, and `StudyUser.getStudyUserRights()` allocates a new `ArrayList` and re-maps every integer **on every single call** (`StudyUser.java:134-140`), which `UserRights.hasStudyRights` invokes per study (`UserRights.java:44`).

The real consistency boundary is the **replication lag**, and it is unbounded on failure:

- The broadcast happens **inside** the master's JPA transaction (`StudyUserServiceImpl.java:128-132`, `:137-144`), with no outbox and no publisher confirms. DB-commit-then-publish-fails ⇒ replicas never learn. Publish-succeeds-then-rollback ⇒ replicas hold rights the master never granted.
- On the consumer side, any deserialization or persistence error becomes `AmqpRejectAndDontRequeueException` (`RabbitMqStudyUserService.java:65-67`) and, with no DLQ, the command is **gone**. A dropped `DELETE` is a permanently un-revoked access grant.
- `processCommands` is **not `@Transactional`**: creates, updates and deletes go through three separate `saveAll`/`deleteByIdIn` calls (`:81`, `:86`, `:90`). A partial failure leaves rights half-applied.
- `UPDATE` commands for ids absent from the local replica are **silently dropped** (`:57-65` only iterates rows found in the DB). Once a replica diverges, it stays diverged; there is no reconciliation job and no drift detection. The only known repair is a manual cross-database SQL migration — which is exactly what `docker-compose/database-migrations/db-changes/datasets/0054_study_users_update.sql` does (delete everything in `datasets.study_user`, re-insert from `studies.study_user`).

### 5.3 The `ObjectMapper` mutation

```java
// shanoir-ng-study-rights/.../ampq/RabbitMqStudyUserService.java:59-63
SimpleModule module = new SimpleModule();
module.addAbstractTypeMapping(StudyUserInterface.class, StudyUser.class);
mapper.registerModule(module);
commands = mapper.readValue(commandArrStr, StudyUserCommand[].class);
```

`mapper` is the **shared, Spring-managed `ObjectMapper` singleton**, used by every controller and every other listener in the process. This block runs on **every message**, on a container with 10–100 concurrent consumers (`RabbitMQDatasetsService.java:155` selects `multipleConsumersFactory`).

- `ObjectMapper.registerModule` mutates the mapper's deserialization config. Jackson's contract is that a mapper is configured before use and then treated as immutable; concurrent reconfiguration while other threads are deserializing is undefined behaviour.
- An anonymous `SimpleModule` has no type id, so `IGNORE_DUPLICATE_MODULE_REGISTRATIONS` cannot dedupe it. Each call appends another `SimpleAbstractTypeResolver` — an unbounded, slow leak on a hot path.

The whole thing exists only because `StudyUserCommand.studyUser` is declared as an interface (`StudyUserCommand.java:22`). Registering the mapping once at startup (a `@Configuration`-level `SimpleModule` bean), or simply typing the field as `StudyUser`, removes the problem entirely.

### 5.4 Fail-open / fail-closed analysis

| Failure mode | Behaviour | Verdict |
|---|---|---|
| RabbitMQ down (broadcast side) | `MicroServiceCommunicationException` thrown from inside the master's `@Transactional`; DB change may already be flushed | **Fail-open for revocations** — replicas keep the old (broader) rights |
| RabbitMQ message rejected (consumer side) | `AmqpRejectAndDontRequeueException`, no DLQ ⇒ discarded | **Fail-open for revocations**, permanently |
| Commands reordered by concurrent consumers | `DELETE` may land before `CREATE`/`UPDATE` | **Fail-open** — revoked rights can be resurrected |
| Local DB unreachable | Repository throws; the SpEL `@PreAuthorize` evaluation fails | Fail-closed (500) |
| `userId` claim absent from token | `IllegalStateException` (`StudyRightsService.java:45-47`) — except in `getUserRights()`, which passes `null` to the repository and yields an empty `UserRights` | Fail-closed both ways |
| Unknown right id in the DB | `StudyUserRight.getType` throws `IllegalArgumentException` (`StudyUserRight.java:80`) from inside `StudyUser.getStudyUserRights()` | Fail-closed, but see §8 — this makes a new right value break *all* checks on old replicas |
| `studyUserRights` column empty/null | `StudyUser.getStudyUserRights()` iterates a null list ⇒ **NPE** (`StudyUser.java:136`) | Fail-closed by accident |
| No center restrictions on a `StudyUser` | `hasRightOnCenter` returns **true** for every center | **Fail-open by design** |

The last row deserves its own treatment:

```java
// shanoir-ng-study-rights/.../StudyRightsService.java:76-88
public boolean hasRightOnCenter(Long studyId, Long centerId) {
    Long userId = KeycloakUtil.getTokenUserId();
    if (userId == null) { throw new IllegalStateException(...); }
    StudyUser founded = repo.findByUserIdAndStudyId(userId, studyId);
    List<Long> centerIds = repo.findCenterIdsByStudyUserId(founded.getId());   // ← NPE if founded == null
    founded.setCenterIds(centerIds);
    return
            founded != null                                                     // ← dead null check
            && (founded.getCenterIds().isEmpty() || founded.getCenterIds().contains(centerId));
}
```

Three defects in twelve lines: the null check at line 85 is **after** two dereferences at lines 82–83; unlike every sibling method this one checks **neither `isConfirmed()` nor any `StudyUserRight`**, so the mere existence of a `study_user` row grants center access; and an empty center list means "all centers". The `Set<Long>` overload (`:93-110`) repeats the same missing checks.

Two further methods drop the null guard their siblings have: `hasRightOnStudies` (`:147`) and `hasRightOnAtLeastOneStudy` (`:169`) call `su.getStudyUserRights().contains(...)` directly, whereas `hasRightOnStudy` (`:51`) guards it. As noted, that guard is itself dead code — `getStudyUserRights()` never returns null; it throws.

### 5.5 Zero-test risk

746 lines of security-critical code, 6 public authorization methods, 8 distinct failure modes above — and **not one test**. The behaviours that must be pinned before any refactor: unconfirmed users are denied; an empty rights list is denied; center restrictions are honoured; a missing `StudyUser` row is denied (not a 500); command batches apply atomically; out-of-order batches converge to the master's state.

---

## 6. `shanoir-ng-anonymization` deep-dive

1,199 LOC. Two real classes (`AnonymizationServiceImpl` 691, `AnonymizationRulesSingleton` 150), a rule spreadsheet, and a UID generator. **Zero executable tests.**

### 6.1 Profile format and location

Rules live in **`shanoir-ng-anonymization/src/main/resources/anonymization.xlsx`** — a binary Excel workbook inside the jar, parsed with Apache POI at class-load time (`AnonymizationRulesSingleton.java:52-136`). A second copy sits at `docs/Anonymization/anonymization.xlsx` alongside `Anonymization Spec.xlsx` and a `.docx`.

Sheets:
- **`Profiles`** — columns: `Attribute Name | Tag | 0xTag | Profile Basic | Profile MR | Profile OFSEP | Profile Neurinfo`. 645 tag rows load successfully.
- **`TagsToDeleteForManufacturer`** — exactly **two** entries, both `GE MEDICAL SYSTEMS` (`0x00331013`, `0x0033101C`). The `SIEMENS / 0x00xxxxxx` text in columns C–D is an inline example the loader never reads (`:112-117` reads columns 0 and 1 only).
- **`Legend`** — defines `D`, `Z`, `X`, `K`, `C`, `U`, `X/Z`, `X/D`, `Z/D`, `X/Z/D`, `X/Z/U*`. Note `K` is defined as *"keep (unchanged for non-sequence attributes, **cleaned for sequences**)"*.
- **`Analysis for Profile MR`** — documentation only.

Loader defects:

| Issue | Location |
|---|---|
| A row is only loaded if the `0xTag` cell is **exactly 10 characters**. `Device Description (0050,0020)` is written `0x0050020` (9 chars — a missing zero), so it is **silently dropped and never anonymized**. | `AnonymizationRulesSingleton.java:87`, xlsx `Profiles` row 110 |
| `actionCell.getStringCellValue()` with no null check. Rows 107/242/356 have present-but-blank cells (POI returns `""`), which works by luck; a genuinely absent cell returns `null` ⇒ **NPE inside a static initializer ⇒ `ExceptionInInitializerError` on first anonymization**. Editing the workbook in a tool that trims trailing cells triggers this. | `AnonymizationRulesSingleton.java:93-94` |
| Only `IOException` is caught. `getResourceAsStream` returning null, a POI parse error or the NPE above escape as `Error`. | `:132-134` |
| `InputStream in` is never closed. | `:58` |
| `getProfiles()` / `getTagsToDeleteForManufacturer()` return the **live mutable maps**. Any caller can rewrite the anonymization rules at runtime. | `:142-148` |
| Manufacturer matching is an exact, case-sensitive, untrimmed `Map.get(manufacturer)`. `"SIEMENS"`, `"Siemens Healthineers"`, `"Philips Medical Systems"` have no entries at all. | `AnonymizationServiceImpl.java:369` |
| A binary `.xlsx` is unreviewable in a pull request — the single most safety-critical configuration in the platform cannot be diffed. | — |

### 6.2 Action distribution across the four profiles

| Action | Basic | MR | OFSEP | Neurinfo | Semantics as implemented |
|---|---:|---:|---:|---:|---|
| `X` (remove) | 384 | 405 | 395 | 393 | `attributes.remove(tag)` ✔ |
| `D` (dummy) | 92 | 89 | 89 | 89 | `new BigInteger(130, SecureRandom).toString(32)` — a random base-32 string |
| `U` (new UID) | 56 | 55 | 55 | 55 | `UIDGeneration.getNewUID()` ✔ |
| `Z` (zero-length) | 42 | 47 | 44 | 44 | empty string ✔ |
| `K` (keep) | 0 | 2 | 15 | 17 | left untouched — **never "cleaned for sequences"** |
| `X/D` | 28 | 16 | 16 | 16 | **not implemented → blanked** |
| `X/Z` | 17 | 4 | 4 | 4 | **not implemented → blanked** |
| `X/Z/D` | 14 | 1 | 1 | 1 | **not implemented → blanked** |
| `Z/D` | 9 | 1 | 1 | 1 | **not implemented → blanked** |
| `X/Z/U*` | 4 | 0 | 0 | 0 | **not implemented → blanked (UIDs not re-mapped)** |
| *(blank)* | 0 | 3 | 3 | 3 | **undefined → blanked** |

### 6.3 Tag-by-tag findings

**(a) Compound actions are silently degraded to "blank".**

```java
// AnonymizationServiceImpl.java:527-549
private String getFinalValueForTag(final String action) {
    String result = "";
    if (action != null) {
        if (action.equals("X"))      result = null;
        else if (action.equals("Z")) result = "";
        else if (action.equals("D")) result = new BigInteger(130, SECURE_RANDOM).toString(32);
        else if (action.equals("U")) { … }
        else if (action.equals("K")) result = "KEEP";
    }
    return result;                       // "X/Z", "X/D", "Z/D", "X/Z/D", "X/Z/U*", "" all fall through
}
```

Anything not in that list returns `""`, and `anonymizeTag` then calls `anonymizeTagAccordingToVR(attributes, tag, "")` (`:438-442`). For `X/Z` the outcome is coincidentally acceptable. It is **wrong** for:
- `Referenced Image Sequence (0008,1140)` and `Source Image Sequence (0008,2112)` in Profile Basic — spec says re-map the contained UIDs (`U`), implementation blanks the sequence.
- Every `X/D` date/time tag (`Instance Creation Date (0008,0012)`, `Date of Last Detector Calibration (0018,700C)`, `RT Plan Date (300A,0006)`, …) — spec says substitute a consistent dummy, implementation produces a zero-length date.
- Numeric-VR tags: `Integer.decode("")` and `Double.valueOf("")` throw `NumberFormatException` (`:570`, `:573`), which is **not** caught by the `catch (IOException)` at `:332` and therefore aborts the entire batch mid-file, after the file has possibly already been truncated by `new DicomOutputStream(dicomFile)`.

Also note that `D` produces a base-32 string like `3k7f2ha9xq…` regardless of VR. Written into a `DA`/`TM`/`DT` tag that is a **non-conformant DICOM value**, and into an `IS`/`DS` tag likewise; into `SL`/`UL`/`SS`/`US`/`AT`/`FD`/`FL` it throws.

**(b) Sequences are never traversed.**

`for (int tagInt : datasetAttributes.tags())` (`:275`) enumerates **top-level** tags only. Nothing descends into `Sequence` items. Consequences:

- A sequence not listed in the profile survives **entirely**, including every nested identifier. Concretely: `(0040,0275) Request Attributes Sequence` *is* listed (`X`) and gets removed, but any vendor or IOD-specific SQ that is absent from the 645-row list keeps its whole subtree.
- `(0400,0561) Original Attributes Sequence` — the standard "here is what I changed and what the original values were" sequence — is absent from the profile and therefore preserved verbatim if a prior system wrote it.
- The Legend's own definition of `K` ("cleaned for sequences") is not implemented anywhere.
- When a SQ *is* matched with `Z`/`D`, `anonymizeTagAccordingToVR` calls `attributes.setNull(tag, VR.SQ)` (`:581-582`), destroying the whole sequence rather than cleaning it — the opposite failure.

**(c) Private tags: kept by default in the two production profiles.**

Profile OFSEP and Profile Neurinfo set `0xggggeeee` (private attributes) to **`K`** (xlsx row 378). Private tags are then kept unless a string heuristic fires:

```java
// AnonymizationServiceImpl.java:279-289
if ((group & 1) == 1) {
    String action = anonymizationMap.get(PRIVATE_TAGS);
    String value = datasetAttributes.getString(tagInt);
    if (value != null && !value.isEmpty() && action.equals("K")) {
        action = checkForPHIInPrivateTags(patientNameArrayAttr, patientIDAttr, patientBirthNameAttr,
                                          patientBirthDateAttr, tagInt, value, action);
        action = handleTagsToDeleteForManufacturer(tagToHexString(tagInt), tagsToDeleteForCurrentManufacturer, action);
    }
    anonymizeTag(tagInt, action, datasetAttributes, true, stats);
}
```

The heuristic (`:389-414`) only removes a private tag whose **string** value literally contains the patient name part, patient ID, birth name or birth date — and only if that comparison value is longer than 2 characters (`:408`). It therefore does **not** catch:
- binary private tags, where `getString` returns null or garbage (the branch is skipped entirely) — this includes the **Siemens CSA headers `(0029,1010)` / `(0029,1020)`**, which routinely embed patient and protocol information;
- private tags containing an accession number, referring physician, institution, operator name, local MRN or scanner-side comment;
- any encoding variant (accents, `^` separators, case differences) of the patient name.

Only **two** manufacturer-specific private tags are configured, both GE. There are zero entries for Siemens, Philips, Canon or Hitachi.

If `PRIVATE_TAGS` were ever missing from a profile, `action.equals("K")` at line 283 would NPE.

**(d) `patientNameArrayAttr` can be null ⇒ NPE aborts the batch.**

`patientNameArrayAttr` is only assigned when `PatientName` is non-empty (`:255-258`), but lines 248-251 explicitly `setNull` the tag when absent — so a DICOM file with no `PatientName` (already-anonymized data, some secondary captures) leaves it `null`. `checkForPHIInPrivateTags` then does `for (int i = 0; i < patientNameArrayAttr.length; i++)` (`:393`) ⇒ **NullPointerException**, uncaught, aborting the whole import.

**(e) Overlay group range test mis-classifies.**

```java
// AnonymizationServiceImpl.java:311-320
if (0x50000000 <= tagInt && tagInt <= 0x50FFFFFF)      { /* curve data     */ }
else if (0x60004000 <= tagInt && tagInt <= 0x60FF4000) { /* overlay comments */ }
else if (0x60003000 <= tagInt && tagInt <= 0x60FF3000) { /* overlay data     */ }
```

These are arithmetic range tests on the full 32-bit tag, not `(group in 6000..60FF) && (element == 3000|4000)`. `(6002,3000)` = `0x60023000` satisfies the **first** 60xx branch (`0x60004000 ≤ 0x60023000 ≤ 0x60FF4000`) and is therefore treated as an *overlay comment*, not overlay data. Only `(6000,3000)` itself reaches the correct branch. Both rows happen to be `X` in all four profiles today (xlsx rows 306-307), so the bug is currently latent — it becomes real the moment the two rows differ. Separately, overlay elements other than `3000`/`4000` (e.g. `(60xx,0022) Overlay Description`, free text) match **no** branch and are never touched.

**(f) The UID generator.**

```java
// UIDGeneration.java:23-45
public static final String ROOT = "1.4.9.12.34.1.8527";
```

- 18-char root + `.` + 40 digits = 59 chars, within the 64-byte `UI` limit ✔.
- `1.4.…` is **not a registered OID arc** (ISO assigns `1.0` standard, `1.1` registration-authority, `1.2` member-body, `1.3` identified-organization; `1.4` is unassigned). Shanoir is minting UIDs under a namespace it does not own — a DICOM conformance problem and a (small) collision risk across institutions.
- `rand.nextInt(9) + 1` with `lUUID.replaceFirst("0", …)` (`:42-43`) is correct only because `startsWith("0")` was already checked; `replaceFirst` takes a regex and would otherwise patch the wrong position.
- `java.util.Random` shared via the static `UID_GENERATOR` in `AnonymizationServiceImpl:65`.

**(g) UID re-mapping consistency.**

The four remap tables (`seriesInstanceUIDs`, `frameOfReferenceUIDs`, `studyInstanceUIDs`, `studyIds`) are created **per `anonymize()` call** (`:81-84`, `:121-124`) and are plain `HashMap`s. Within one call the mapping is consistent. Across calls it is not: two invocations over files of the same series produce **different** `SeriesInstanceUID`s. Since `ImporterManagerService` passes the whole file list in one call, this is safe today, but chunking or parallelising the import would silently split series. There is nothing in the code that documents or enforces the invariant.

`SOPInstanceUID` is handled specially: the body tag is overwritten with the value already generated for the header's `MediaStorageSOPInstanceUID` (`:493-498`), keeping header and dataset aligned — this is correct and well-commented (`:170-184`).

`StudyID` is regenerated as 10 lowercase letters from a **shared `java.util.Random` instance field** (`:67`, `:509`) — not `SecureRandom`, and not thread-safe. ~47 bits of entropy, adequate as a label but predictable.

**(h) Dates and times.**

`PatientBirthDate` is truncated to `YYYY0101`, falling back to `19000101` (`:159-167`) — a reasonable generalisation. But `Study Date`, `Series Date`, `Acquisition Date` and `Acquisition Time` are **`K` (kept verbatim)** in Profiles OFSEP and Neurinfo. There is no date-shifting option and no `(0012,0052)/(0012,0053) Longitudinal Temporal Offset` tags to record one.

**(i) Failure handling destroys or leaks data.**

```java
// AnonymizationServiceImpl.java:329-334
dos = new DicomOutputStream(dicomFile);          // truncates the file being read
dos.writeDataset(metaInformationAttributes, datasetAttributes);
…
} catch (final IOException exc) {
    LOG.error("performAnonymization : error while anonimizing file " + dicomFile.toString() + " : ", exc);
}
```

The exception is **swallowed**. The caller (`anonymize` / `anonymizeForShanoir`) has no way to know a file failed, and the import continues. Two outcomes, both bad:
- read failed ⇒ the original PHI-bearing file remains on disk and is imported as-is (**fail-open**);
- write failed part-way ⇒ the file is truncated and the source data is destroyed (there is no temp-file-and-rename).

There is no post-condition verification anywhere: nothing re-reads the output and asserts that `PatientName` is the pseudonym.

**(j) Mutable static state.**

`private static Map<String, List<String>> tagsToDeleteForManufacturer` (`:69`) is assigned from `anonymize`/`anonymizeForShanoir` (`:78`, `:118`). ms-import holds a **single static `AnonymizationServiceImpl`** (`shanoir-ng-import/.../ImporterManagerService.java:79`) shared across concurrent imports. Today every assignment writes the same singleton reference, so the race is benign, but the public `performAnonymization` overload (`:196-204`) reads that static without ever setting it — calling it directly, as its javadoc invites ("Overload kept for backward compatibility with existing external callers"), yields an **NPE at line 369**.

**(k) No profile validation.**

`profiles.get(profile).getAnonymizationMap()` (`:77`, `:117`) — an unknown or null profile name is an **NPE**, not a clear error. Valid names are the literal spreadsheet headers `"Profile Basic"`, `"Profile MR"`, `"Profile OFSEP"`, `"Profile Neurinfo"`. In the zip-import path the server fetches the profile from ms-studies (`ImporterApiController.java:905,914`), which is correct; `ImporterManagerService.pseudonymize` then reads `importJob.getAnonymisationProfileToUse()` (`:221,232`) — the library itself performs no check that the value is server-controlled.

### 6.4 Gap analysis vs DICOM PS3.15 Annex E

| PS3.15 requirement | Status | Evidence |
|---|---|---|
| Apply the Basic Application Level Confidentiality Profile action codes | **Partial** — `X`, `Z`, `D`, `U`, `K` implemented; all five compound codes are not | `AnonymizationServiceImpl.java:527-549` |
| Set **(0012,0062) Patient Identity Removed = YES** | **Missing** — tag absent from the workbook and never written | grep `0x00120062` → 0 hits |
| Set **(0012,0063) De-identification Method** | **Missing** | grep `0x00120063` → 0 hits |
| Set **(0012,0064) De-identification Method Code Sequence** | **Missing** | grep `0x00120064` → 0 hits |
| Clean recursively inside Sequences | **Missing** | `:275` |
| Handle **(0028,0301) Burned In Annotation** / Clean Pixel Data option | **Missing** — the tag is not in the profile and no pixel data is inspected | grep `0x00280301`, `0x7FE00010` → 0 hits |
| Retain-Longitudinal-Temporal-Information option tags **(0012,0052)/(0012,0053)** | **Missing** — dates are kept verbatim in OFSEP/Neurinfo with no option declared | xlsx rows for `0x00080020`, `0x00080021`, `0x00080022` = `K` |
| Retain-Device-Identity option — `Device Serial Number`, `Station Name`, `Institution Name/Address` | **Kept without declaring the option** (OFSEP keeps all four) | xlsx rows 112, 215, `0x00080081` |
| Retain-Patient-Characteristics option — `Patient Sex`, `Age`, `Size`, `Weight` | **Kept without declaring the option** | xlsx rows for `0x00100040`, `0x00101010`, `0x00101020`, `0x00101030` |
| Retain-Safe-Private option | **Effectively enabled** for OFSEP/Neurinfo (`0xggggeeee` = `K`) via a string heuristic, not a curated safe-private list | xlsx row 378 |
| `(0010,0024) Issuer of Patient ID Qualifiers Sequence` | **Missing from the profile** | grep → 0 hits |
| `(0032,1064) Requested Procedure Code Sequence` | **Missing from the profile** | grep → 0 hits |
| `(0008,0008) Image Type` (can carry site-specific free text) | **Missing from the profile** | grep → 0 hits |
| `(0050,0020) Device Description` | In the profile but **silently dropped** by the 10-char loader check | xlsx row 110 |
| Ensure UID consistency within a set of instances | ✔ within one `anonymize()` call, undefined across calls | `:81-84` |
| Curve / Overlay data removal | Partially — `(50xx,xxxx)` correct, `(60xx,3000)` mis-routed for groups ≠ 6000, other overlay elements unhandled | `:311-320` |

Bottom line: **Profile Basic is a partial implementation of PS3.15 Annex E; Profiles OFSEP and Neurinfo are deliberate retain-variants that do not declare the corresponding PS3.15 options and do not mark the data as de-identified at all.** A downstream consumer receiving these files has no machine-readable way to know they were processed, nor what was retained.

### 6.5 Residual re-identification risk

For a file processed with **Profile OFSEP or Profile Neurinfo** the following typically survive:

1. **Exact acquisition timestamps** — `Study Date`, `Series Date`, `Acquisition Date`, `Acquisition Time`. Together with a known scanner these narrow a subject to a specific appointment slot; cross-referenced against a hospital RIS this is often a unique identifier.
2. **Scanner identity** — `Device Serial Number`, plus `Institution Name`/`Institution Address` under OFSEP. Combined with (1), site + machine + minute.
3. **Study/Series Description and Protocol Name** — free-text fields operators routinely use for local notes; no scanning, no redaction.
4. **All private tags whose value is binary or does not literally contain the patient name/ID/birth-name/birth-date**, including Siemens CSA headers.
5. **Everything nested inside any sequence not explicitly listed** in the 645-row table.
6. **Burned-in pixel annotation** — never examined. Screenshots, secondary captures and dose reports frequently carry the patient name rendered into the image.
7. **Patient Sex, Age, Size, Weight** (Neurinfo) — quasi-identifiers.
8. **`Device Description (0050,0020)`** — dropped by the loader bug regardless of profile.
9. The **subject pseudonym itself** where OFSEP-style identifiers are used: SHA-1 of `firstName+lastName+birthDate`, unsalted, truncated (§7.1).

Combining (1)+(2)+(7) already constitutes a strong quasi-identifier set. Under GDPR these outputs are **pseudonymised personal data**, not anonymous data, and must be handled as such (Recital 26). The absence of `(0012,0062)` means nothing in the file says so.

### 6.6 Concrete test strategy

**Golden-file tests (highest value).** Commit a small corpus of synthetic DICOM files under `src/test/resources/dicom/` — build them programmatically with dcm4che so no patient data is ever committed:

| Fixture | Must assert |
|---|---|
| `mr-siemens-full-header.dcm` | full tag-by-tag diff of input vs output for each of the 4 profiles, stored as a committed `.txt` golden file — a rule change becomes a reviewable text diff |
| `with-nested-sequences.dcm` | PHI inside `RequestAttributesSequence` and a private SQ is removed (**currently fails**) |
| `no-patient-name.dcm` | does not throw (**currently NPEs**, `:393`) |
| `siemens-csa-binary.dcm` | private binary tags handled per the profile's intent |
| `multi-series-multi-instance/` (6 files, 2 series) | one new `SeriesInstanceUID` per input series; `SOPInstanceUID` == `MediaStorageSOPInstanceUID` in every output |
| `numeric-vr-with-compound-action.dcm` | no `NumberFormatException` (**currently fails**) |
| `overlay-6002-3000.dcm` | overlay data uses the overlay-data action, not the comments action |
| `unreadable.dcm` (0 bytes) | the method **throws** rather than silently leaving the file (**currently fails**) |

**Property-based tests** (jqwik or hand-rolled generators):
- For any generated `Attributes` and any profile: no output tag value equals the input `PatientName`, `PatientID`, `PatientBirthName` or `PatientBirthDate` — at *any* nesting depth.
- Idempotence: `anonymize(anonymize(x))` differs from `anonymize(x)` only in regenerated UIDs.
- UID injectivity: distinct input `SeriesInstanceUID`s map to distinct outputs; equal inputs map to equal outputs.
- Every action letter in the workbook is one the code understands — a **parser test over `anonymization.xlsx` itself** would have caught the 49 compound-action rows, the 3 blank cells and the malformed `0x0050020` in one assertion.

**Conformance test.** Assert `(0012,0062) == "YES"` and that `(0012,0063)` names the profile — after implementing them.

**Concurrency test.** Run `anonymizeForShanoir` from 8 threads on disjoint file sets against the shared static instance and assert no cross-contamination of UID maps.

---

## 7. `exchange`, `storage`, `keycloak-auth`

### 7.1 `shanoir-ng-exchange` (636 LOC, 6 main / 2 test)

**Purpose.** The "Shanoir Exchange Format" (SEF): a JSON descriptor (`shanoir-exchange.json`) describing an import/export as study → study-cards → subjects → examinations, plus the subject-identifier calculator. Consumed by ms-import and by ShanoirUploader.

**Structure.** `Exchange` → `ExStudy` → {`ExStudyCard`, `ExSubject` → `ExExamination`}. The format is **half-built**: every class carries a commented-out field for the "full object" case (`ExStudy.java:38-43`, `ExSubject.java:35-53`, `ExExamination.java:31-38`, `ExStudyCard.java:31-38`) with `//todo: complete here later`. Only the by-name/by-id reference case works.

**`IdentifierCalculator` — the real problem.**

```java
// IdentifierCalculator.java:88-107
private String calculateSHA(final String subjectIdentifierSeed) … {
    String hex = "";
    final MessageDigest msgDigest = MessageDigest.getInstance(SHA);      // "SHA" == SHA-1
    msgDigest.update(subjectIdentifierSeed.getBytes(UTF_8));
    byte[] hash = msgDigest.digest();
    for (int i = 0; i < hash.length; i++) {
        hashInt = hash[i] & 0xFF;
        if (hashInt < 16) hex += "0";
        hex += (Integer.toString(hashInt, 16).toUpperCase() + "");
        hex = hex + Byte.toString(hash[i]);                              // signed decimal appended too
    }
    return hex.substring(0, HASH_LENGTH);                                // first 14 chars
}
```

- **SHA-1**, used to pseudonymise patients.
- **No salt, no pepper, no key.** The input is `firstName + lastName + birthDate` (`:69`), a very low-entropy space. An attacker holding an identifier can enumerate plausible name/date combinations offline and recover the patient — the classic unsalted-hash-of-a-name failure. This is precisely the case the CNIL/EDPB guidance on pseudonymisation calls out.
- The loop appends both the unsigned hex byte **and** the signed decimal byte (hence the `-` characters in the committed expectation `"AB-859C-100131"`, `IdentifierCalculatorTest.java:44`), then truncates to 14 characters — roughly the first 4–5 source bytes. Effective entropy is far below 14 hex nibbles, and the collision rate is much higher than the length suggests.
- The other overload keys on `newPatientID + birthDate` where `birthDate` is a `java.util.Date` (`:82-85`), so the seed contains **`Date.toString()`** — `"Wed Jan 01 00:00:00 CET 2020"`. That string is **locale- and timezone-dependent**: change the container's `TZ` or default locale and every subject in the system gets a new identifier, silently breaking longitudinal linkage.
- Inconsistently, `calculateIdentifierWithHashs` (`:41-53`) uses proper SHA-256 and emits a full 64-char hex digest. Two identifier schemes coexist with different security properties.
- Minor: `"UTF-8"` string instead of `StandardCharsets.UTF_8`, forcing `UnsupportedEncodingException` through every signature; `StringBuffer` instead of `StringBuilder` (`:45`).

**Tests.** `IdentifierCalculatorTest` has 2 real assertions and is the only genuine regression guard in the module — but it *pins the broken algorithm*, so fixing it requires a data migration. `ExchangeModelTest.testCreateJson` (`:22-49`) builds an object, serialises it and calls `System.out.println` — **zero assertions**. Both use JUnit 4.12 with `org.mockito.runners.MockitoJUnitRunner` (the deprecated Mockito-1 package, still shipped in mockito-core 3.4.0, so they do compile and run).

**Build.** No `<parent>` (`shanoir-ng-exchange/pom.xml:17-27`), Java 17, and **`jackson.version` pinned to `2.13.4.1`** (`:38`) — a 2022 release, well behind Spring Boot 3.4's Jackson. Within this module it is the effective version; consumers with `dependencyManagement` override it, but `shanoir-uploader` may not.

### 7.2 `shanoir-ng-storage` (1,319 LOC, 4 main / **0 tests**)

**Purpose.** One `StorageService` interface (134 LOC, ~35 methods + 10 constants) with two `@ConditionalOnProperty`-selected implementations: `FileSystemStorageService` (`storage.type=file-system`, default) and `S3StorageService` (`storage.type=s3`).

**Issues.**

| Sev | Issue | Location |
|---|---|---|
| High | **Path traversal on write.** `dirPath.resolve(fileName)` with no `normalize()` and no containment check. A `fileName` containing `../` escapes the base directory. | `FileSystemStorageService.java:212-216` |
| High | **Path traversal on read.** `URLDecoder.decode(fileName, UTF_8)` *then* `Paths.get(baseDir, directory, decoded)`. Decoding first means `%2e%2e%2f` becomes `../`. `loadDatasetsData(String path)` takes a raw caller-supplied path. | `:258-260`, `:268-269`, `:242-244` |
| Medium | **`prefix != ""` — reference comparison.** For an intentionally empty S3 prefix the guard falls through to `!"".endsWith("/")` and throws at startup, defeating the code's own stated intent that an empty prefix is legal. | `S3StorageService.java:528` |
| Medium | **Bucket creation fails open.** `catch (Exception e) { LOG.error(...) }` — the service starts happily with a missing/inaccessible bucket and every upload fails later. | `:544-546` |
| Medium | `getPublicLocation*` on the filesystem impl returns `file:///var/…` URIs built from the internal path, which are then persisted and returned by the API — leaking the host layout. | `FileSystemStorageService.java:304-316`, `:217` |
| Low | `deleteFolder`-style recursion via `Files.walk(...).sorted(reverseOrder())` follows into whatever is under the directory with no symlink guard. | `:383-400` |
| Low | `@Autowired` on `final` fields that are also constructor-injected — misleading no-ops. | `S3StorageService.java:475-479, 502-503` |
| Low | Duplicate `import java.util.Arrays;` (legal but sloppy) plus ~8 unused imports (`Path`, `Duration`, `MissingResourceException`, `Profile`, `HeadObjectRequest`, …). | `:422, 428` |
| Low | `uploadMultipart` allocates an 8 MB heap buffer per invocation; concurrent large uploads multiply that. | `:719` |
| Design | A 35-method god interface with `Study`/`Examination`/`Acquisition`/`Preclinical`/`PathologyModel` variants of the same four operations. Adding an entity type means editing the interface and both implementations. | `StorageService.java:849-960` |

**Tests: none.** For a module whose entire job is deriving filesystem/object keys from user input, this is the highest test-value-per-line in the whole layer. A dozen parameterised tests over `store`/`load` key construction (including `../`, URL-encoded traversal, unicode, and empty S3 prefixes) would take an afternoon.

### 7.3 `shanoir-ng-keycloak-auth` (286 LOC, 2 main / **0 tests**)

**Purpose.** A Keycloak `Authenticator` SPI (`shanoir-ng-post-auth`) registered via `META-INF/services/org.keycloak.authentication.AuthenticatorFactory`, packaged as a fat jar by the assembly plugin and dropped into the Keycloak container. It runs after every successful authentication and does three things: enforce an account expiry date, restrict admin logins by source IP, and POST the username to `ms-users /last_login_date`.

**Issues.**

| Sev | Issue | Location |
|---|---|---|
| **High** | `private static final SimpleDateFormat EXP_DATE_FORMAT` — `SimpleDateFormat` is **not thread-safe** and `authenticate()` runs concurrently for every login. Concurrent `parse()` yields wrong dates or `NumberFormatException`/`ArrayIndexOutOfBoundsException`, so a valid account can be denied or an **expired account admitted**. | `:86`, used at `:129` |
| **High** | `client.execute(request)` with a `HttpClient` built per login and **never closed**, and **no connect/socket timeouts configured**. If ms-users is slow or hung, the Keycloak login thread blocks indefinitely — a login outage triggered by an unrelated service. The response is never consumed either, so pooled connections are never released. | `:170-181` |
| Medium | Pattern typo: `"yyy-MM-dd"` (three `y`s). Lenient parsing makes it usually work, but `format()` would be wrong and 2-digit years get the sliding-window interpretation. No `setLenient(false)`, so `"2026-13-45"` rolls over silently. No explicit `TimeZone`, so expiry is evaluated in the container's default zone. | `:86, 122-135` |
| Medium | `user.setEnabled(false)` on expiry (`:139`) permanently disables the account; extending the expiry date is no longer sufficient to restore access. | `:137-142` |
| Medium | The admin IP allow-list is **null when the `allowed.admin.ips` property is unset**, which means "admins may log in from anywhere" (`:59-73`, `:146`). If every configured IP is invalid the list is empty, which means "nobody may log in". Two opposite fail modes from adjacent inputs. | `:59-73` |
| Medium | `context.getConnection().getRemoteAddr()` behind nginx returns the client IP **only if** Keycloak trusts the forwarded headers. `docker-compose/keycloak/entrypoint:48` sets `KC_PROXY_HEADERS=xforwarded`, so it does work — but the control silently degrades to "always the proxy IP" if that env var is ever changed, and nothing detects it. | `:105`, entrypoint:48 |
| Medium | `new StringEntity(user.getUsername())` sent with `Content-type: application/json` is **not valid JSON** (no quotes), and `StringEntity(String)` in httpclient 4.5 defaults to **ISO-8859-1**, mangling non-ASCII usernames. | `:176-178` |
| Medium | `/last_login_date` is `permitAll()` on ms-users (`shanoir-ng-users/.../SecurityConfiguration.java:76-78`) and takes the username as an unauthenticated request body — anyone who can reach ms-users can forge login timestamps. | — |
| Low | `java.version` 11 and artifact version `1.0.0`, out of step with the rest of the product; not covered by the Checkstyle workflow; the only two `FIXME`s in the shared layer live here. | `pom.xml:23,32`, `:54`, `:124` |

---

## 8. Shared-code coupling analysis

### 8.1 The shared schema

`study_user` is the clearest case. One logical table, **four physical copies**:

| Database | Owner class | Role |
|---|---|---|
| `studies` | `shanoir-ng-studies/.../study/model/StudyUser.java:50` (extends `AbstractEntity`, has `@ManyToOne Study`) | master |
| `users` | `shanoir-ng-study-rights/.../StudyUser.java:32` (assigned `@Id`, no `Study` relation) | replica |
| `datasets` | same class | replica |
| `import` | same class | replica |

Two different Java classes map the same logical rows, with different id-generation strategies and different relationship graphs. The DDL is duplicated across four migration directories (`users/0005_create_study_user_tables.sql`, `studies/0009_study_user_center.sql`, `datasets/0015_study_user_center.sql`, `import/0002_study_user_center.sql`), and the reconciliation migrations reach **across schemas** (`users/0005…sql:44-54` and `datasets/0054_study_users_update.sql:16-27` both do `INSERT … SELECT FROM studies.study_user`). That only works because all four "databases" are schemas inside a single MariaDB instance (`docker-compose.yml:87-92`) — the microservice boundary is an illusion at the storage layer.

Beyond `study_user`, `AbstractEntity` (`ms-common`) is the `@MappedSuperclass` of ~70 entities across four services. Changing its id strategy is a four-database migration.

### 8.2 The lockstep triggers

Anything below forces a coordinated release of *all* consumers:

1. **`StudyUserRight` enum** (`ms-common`). `StudyUserRight.getType(id)` **throws `IllegalArgumentException` for an unknown id** (`StudyUserRight.java:80`), and it is called from `StudyUser.getStudyUserRights()` (`StudyUser.java:137`), which every authorization check invokes. Introduce `CAN_XYZ(6)` in ms-studies, let one row propagate to an un-upgraded ms-datasets, and **every rights check for every user in that study throws** until datasets is upgraded. A rolling upgrade of the rights model is impossible.
2. **`ShanoirEventType` constants** are used as **AMQP routing keys** (`ShanoirEventService.java:60`) with bindings hardcoded in consumers (`RabbitMQDatasetsService.java:374`, `RabbitMQStudiesService.java:114,161`). A renamed constant makes messages unroutable and silently dropped (no alternate exchange, no `mandatory` flag).
3. **`RabbitMQConfiguration` queue names.** A renamed constant recompiles cleanly on both sides but produces two queues that never meet.
4. **Shared DTO shapes** (`IdName`, `SubjectStudyDTO`, `Email*`, `CreateCenterForStudyMessage`, …). Removals and renames are silent because of `FAIL_ON_UNKNOWN_PROPERTIES=false` (`JacksonConfiguration.java:50`).
5. **`StudyUser` entity shape.** Adding a field means four schema migrations plus a coordinated deploy, because `processCommands` copies fields explicitly (`StudyUserUpdateService.java:60-64`) and an older replica simply ignores the new one.

### 8.3 Versioning and release

```xml
<!-- shanoir-ng-back/pom.xml:20-31 -->
<parent>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-parent</artifactId>
  <version>3.4.0</version>
</parent>
<groupId>org.shanoir-ng</groupId>
<artifactId>shanoir-ng-back</artifactId>   <!-- no <version> -->
```

`shanoir-ng-back` has **no `<version>` element**, so it inherits `3.4.0` **from Spring Boot**. Every child (`ms-common`, `study-rights`, `users`, `studies`, `datasets`, `import`, `preclinical`, `nifti-conversion`) is therefore versioned `3.4.0` *because that is the Spring Boot version*, and it only matches the product version 3.4.0 by coincidence. Nine poms then hardcode `<version>3.4.0</version>` for `shanoir-ng-ms-common`, `shanoir-ng-storage` and `shanoir-ng-exchange`. **Bumping Spring Boot to 3.5.x renames every backend artifact and breaks all nine hardcoded references.** Fix: give `shanoir-ng-back` an explicit `<version>` and use `${project.version}` in the children.

Publication is `maven_repository.yml`, triggered **`workflow_dispatch` only** (manual) and running `mvn -f ./shanoir-ng-back/pom.xml deploy` to GitHub Packages (`distributionManagement` at `shanoir-ng-back/pom.xml:236-242`). So: released artifacts exist, but they are cut by hand with no tag, no changelog and no relationship to the docker image tags. `shanoir-uploader` — the only consumer that is not built in the same reactor as a matter of course — depends on `shanoir-ng-ms-common:3.4.0` and `shanoir-ng-exchange:3.4.0` and will happily resolve a stale published jar.

### 8.4 What decoupling would require

1. **Stop sharing the entity, share a contract.** `study-rights` should expose a versioned `StudyUserSnapshot` DTO, not a JPA `@Entity`. The replica table becomes an internal detail of each service, free to differ.
2. **Make the rights enum forward-compatible.** `getType` should return `null`/`UNKNOWN` for unrecognised ids and callers should ignore them, instead of throwing.
3. **Version the event and command envelopes.** A `schemaVersion` field plus a consumer-side compatibility test per contract.
4. **An outbox in ms-studies** so the rights broadcast is atomic with the DB write, plus a periodic full-state reconciliation so drift is self-healing rather than requiring a hand-written cross-schema migration.
5. **Split `ms-common`.** Today a change to an email DTO forces a rebuild of every service. Candidate split: `shanoir-contracts` (events, commands, DTOs, queue names), `shanoir-spring-support` (exception handler, Jackson config, MDC filter, paging), `shanoir-security` (Keycloak helpers), `shanoir-test-support` (`AssertUtils`, `JacksonUtils`, `usermock`, and the deleted `TestTrustManager`).

---

## 9. Code quality assessment

**Mutable / static state**
- `AnonymizationServiceImpl.tagsToDeleteForManufacturer` — mutable `static`, written per call (`:69,78,118`), read by an overload that may never have written it (`:369`).
- `AnonymizationRulesSingleton` hands out its live rule maps (`:142-148`).
- `Spring.context` — a mutable static `ApplicationContext` written from a non-volatile field (`Spring.java:14-19`); dead code, but the pattern is copied elsewhere.
- `ShanoirNgPostAuthAuthenticator.allowedAdminIps` — mutable static `ArrayList` populated in a static block from a system property (`:59-73`).

**Thread safety**
- `EXP_DATE_FORMAT` — shared `SimpleDateFormat` on the login path (`keycloak-auth:86`).
- `mapper.registerModule` per message from a 10–100-consumer container (`RabbitMqStudyUserService.java:59-61`).
- `java.util.Random rand` shared via a static service instance (`AnonymizationServiceImpl.java:67`, `UIDGeneration.java:25`).
- `new ObjectMapper()` per call in `SecurityContextUtil.decodeJwtClaims` (`:88`) and `JacksonUtils.serialize` (`:31`) — safe but wasteful.

**Null handling**
- `StudyRightsService.hasRightOnCenter` — dereference before null check (`:82-85`).
- `FieldEditionSecurityManagerImpl.validate` — `orElse(null)` then immediate dereference (`:49-53`).
- `Utils.equalsIgnoreNull` — `getId().equals(...)` on possibly-transient entities (`:79`).
- `Utils.deleteFolder` — `tempFolder.list()` may return null (`:88-90`).
- `KeycloakUtil.canImportFromPACS` — no guard on the claim or on `jwt` (`:79`).
- `AnonymizationServiceImpl.checkForPHIInPrivateTags` — `patientNameArrayAttr` may be null (`:393`).
- `StudyUser.getStudyUserRights` — iterates a possibly-null list (`:136`).
- `RabbitMQStudiesService.getStudyName` — `findById(id).get()` (`:211`).

**Swallowed exceptions**
- `AnonymizationServiceImpl.java:332-334` — the most consequential one; a failed anonymization is invisible.
- `AnonymizationRulesSingleton.java:132-134` — a corrupt rule file logs and yields empty profiles.
- `S3StorageService.ensureBucketExists:544-546`.
- `SecurityContextUtil.decodeJwtClaims:89-91` — `catch (Exception) { return Map.of(); }`.
- The dominant listener idiom across all services: `catch (Exception e) { LOG.error(...) }` then ack.

**Resource leaks**
- `keycloak-auth`: `HttpClient` per login, never closed; response never consumed (`:170-181`).
- `AnonymizationRulesSingleton`: `InputStream` never closed (`:58`).
- `AnonymizationServiceImpl`: `new DicomOutputStream(dicomFile)` opened on the file still open for reading; both closed only in `finally`, and a write failure truncates the source (`:329-345`).

**Date / timezone / locale**
- `DateTimeUtils.dateToLocalDate` uses `ZoneId.systemDefault()` (`:41`) while `localDateToDate` uses UTC (`:46`) — **the round trip is not identity** and can shift a day. The class comment even acknowledges the UTC choice, but only on one side.
- `localDateToSolrString` uses `systemDefault()` (`:100`) — the Solr index depends on the container timezone.
- `IdentifierCalculator.calculateIdentifier(String, Date)` embeds `Date.toString()` in a hash seed (`:83`).
- `keycloak-auth` expiry comparison has no explicit timezone (`:137`).

**Locale-sensitive formatting**
- `AnonymizationServiceImpl.tagToHexString` uses `toUpperCase()` with no locale (`:355`). Under the Turkish locale `i` uppercases to `İ` — hex digits are unaffected, so this is latent, but the same pattern in `IdentifierCalculator.java:101` is on a hashing path.

**Correctness oddities**
- `PageImpl` overrides `add`, `addAll`, `clear`, `remove`, `removeAll`, `retainAll` by delegating to `getContent()`, which Spring Data returns as an **unmodifiable list** — every one of these throws `UnsupportedOperationException` at runtime (`PageImpl.java:60-96`).
- `Utils.toList(Iterable)` returns the *same* instance when the input is already a `List` (`:53-55`), so callers can mutate a Hibernate `PersistentBag` through what looks like a copy.
- `Utils.wildcardToRegex` escapes 11 metacharacters but not `+` (`:222-256`).
- `FieldErrorMap extends HashMap` (`:29`) — inheritance where composition belongs.
- `ShanoirEvent` generates its own primary key as `UUID.randomUUID().getMostSignificantBits() & Long.MAX_VALUE` (`:63`) — 63 bits, client-side, no uniqueness check.
- `ShanoirEvent.setObjectId` silently truncates identifiers over 255 chars (`:120-126`); `setMessage`/`setReport` rewrite U+FFFD to `?` (`:151`, `:161`) — an encoding band-aid.
- `RabbitMQPreclinicalService` elevates with the role string `"ADMIN_ROLE"` (`:62,89`) instead of `"ROLE_ADMIN"` — it matches no Spring Security authority.

**Hardcoded values**
- `'SECRET'` and `'https://shanoir-ng-nginx/auth'` as `@Value` defaults (`KeycloakServiceAccountUtils.java:47-52`).
- `guest`/`guest` in `shanoir-ng-studies/application.yml:74-75`, `shanoir-ng-nifti-conversion/application.yml:31-32`, `docker-compose.yml:460`.
- The magic user id `92233720L` (`SecurityContextUtil.java:51,55`, echoed in `shanoir-ng-datasets/.../PlannedExecutionManager.java:182`).
- `UIDGeneration.ROOT = "1.4.9.12.34.1.8527"`.
- `AnonymizationTest.DICOM_IMAGE_FOLDER_PATH = "/Users/mkain/Desktop/sample1/IMAGES"`.
- `ms.users.url` default `http://users:9901` (`keycloak-auth:83`).

---

## 10. Test coverage analysis

### 10.1 The numbers

| Module | Main LOC | Test classes | Executable test methods | Real coverage |
|---|---:|---:|---:|---|
| `ms-common` | 7,691 | 1 | 6 (`DateTimeUtilsTest`) | one 108-line utility class |
| `study-rights` | 746 | **0** | 0 | none |
| `anonymization` | 1,199 | 1 | **0** (a `main()`, no `@Test`) | none |
| `exchange` | 636 | 2 | 3 (one asserts nothing) | `IdentifierCalculator` only |
| `storage` | 1,319 | **0** | 0 | none |
| `keycloak-auth` | 286 | **0** | 0 | none |
| **Total** | **11,877** | **4** | **9** | **≈1% of lines, 0% of the security-critical paths** |

`DateTimeUtilsTest` is genuinely good — six focused cases covering the DICOM `TM` grammar including padding, fractional digits and invalid input. It is the exception, and it exists because someone recently fixed a bug there.

### 10.2 What that means in practice

- **Every bug in §11 would be caught by a first test.** The `hasRightOnCenter` NPE, the compound-action fallthrough, the `PageImpl` `UnsupportedOperationException`, the `patientNameArrayAttr` NPE, the storage path traversal — none survives a single well-chosen assertion.
- **Refactoring is effectively forbidden.** Nobody can split `ms-common`, change the anonymization engine, or make the rights model forward-compatible, because there is no safety net. That is why `AnonymizationServiceImpl` has grown to 691 lines instead of being decomposed.
- **The topology is untestable by construction.** `@Profile("!test")` on `RabbitMQConfiguration:35` removes the queues *and the container factories* from every test context.
- **The Checkstyle workflow gives a false sense of coverage.** It enforces whitespace, naming, `MagicNumber` and `TodoComment` at `severity=error` across 10 modules, while zero behaviour is verified. Note also that `storage` and `keycloak-auth` are not in the Checkstyle module list at all.

### 10.3 Prioritised test plan

**P0 — before anything else (≈1 week)**

1. **Anonymization golden files** (§6.6). Highest value in the repository: patient privacy, currently zero coverage, and the test harness doubles as executable documentation of the rule table. Start with the workbook-parser test (one assertion catches 49 broken rows), then the sequence and no-PatientName fixtures.
2. **`study-rights` fail-closed suite.** ~20 tests over `StudyRightsService` with an in-memory H2 `study_user`: unconfirmed → denied; empty rights → denied; missing row → denied *(currently NPE)*; center restrictions honoured; empty center list → document the intended semantics and pin it; unknown right id → decide throw-vs-ignore and pin it.
3. **`StudyUserUpdateService` convergence tests.** Apply command batches in every permutation and assert the replica equals the master. This is the test that exposes the out-of-order-consumer bug.

**P1 — next (≈1 week)**

4. **Storage key-construction tests.** Parameterised over `../`, `%2e%2e%2f`, absolute paths, unicode, empty S3 prefix. Cheap, and they close a live traversal hole.
5. **RabbitMQ contract tests.** With Testcontainers (or a `@TestConfiguration` that re-enables the topology), for each queue constant assert: exactly one declaring bean; ≥1 publisher and ≥1 consumer *(this test fails today for 11 queues, which is the point)*; the published payload type deserialises into the consumer's parameter type.
6. **DTO round-trip tests.** `ShanoirEvent`, `StudyUserCommand[]`, all seven `Email*` DTOs, `IdName`, `SubjectStudyDTO`: serialise → deserialise → assert field equality, with a committed JSON golden file per type so wire-format changes become reviewable diffs.

**P2 — then**

7. `keycloak-auth`: a concurrency test on `EXP_DATE_FORMAT` (fails today), expiry-boundary tests, IP allow-list tests including the null/empty distinction.
8. `KeycloakUtil` / `SecurityContextUtil`: anonymous, missing-claim and wrong-token-type paths.
9. `GlobalExceptionHandler`: assert the Shanoir `AccessDeniedException` maps to 403, and that internal messages are not echoed.
10. `IdentifierCalculator`: pin the current output (already done), then add a locale/timezone-varying test that demonstrates the `Date.toString()` instability before fixing it.

---

## 11. Bugs and correctness risks

| # | Sev | Title | Location |
|---|---|---|---|
| B1 | Critical | Broker exposed + `guest/guest` + Java deserialization + ADMIN elevation in listeners | `docker-compose.yml:74-83`; no `MessageConverter` bean; `SecurityContextUtil.java:50` |
| B2 | Critical | Compound PS3.15 actions silently blank the tag (and throw on numeric VRs) | `AnonymizationServiceImpl.java:527-549` |
| B3 | Critical | Sequences never anonymized | `AnonymizationServiceImpl.java:275` |
| B4 | Critical | Anonymization swallows `IOException` — non-anonymized file left on disk, or file truncated | `AnonymizationServiceImpl.java:329-345` |
| B5 | High | Rights replication: dual write, no DLQ, dropped commands = permanent stale access | `StudyUserUpdateBroadcastService.java:41-47`; `RabbitMqStudyUserService.java:65-67` |
| B6 | High | Rights commands processed out of order by 10 concurrent consumers | `RabbitMQDatasetsService.java:152-156` and the import/users equivalents |
| B7 | High | `hasRightOnCenter`: NPE before the null check; no `isConfirmed`/right check; empty list ⇒ all centers | `StudyRightsService.java:76-110` |
| B8 | High | `mapper.registerModule` on the shared `ObjectMapper` per message | `RabbitMqStudyUserService.java:59-61` |
| B9 | High | Shared `SimpleDateFormat` + un-timeout-ed, un-closed `HttpClient` on the Keycloak login path | `ShanoirNgPostAuthAuthenticator.java:86,170-181` |
| B10 | High | Unsalted SHA-1 patient pseudonyms, truncated to 14 chars; `Date.toString()` in the seed | `IdentifierCalculator.java:88-107,82-85` |
| B11 | High | Path traversal (read and write) in the filesystem storage service | `FileSystemStorageService.java:214,258-260` |
| B12 | High | `NullPointerException` when a DICOM file has no `PatientName` | `AnonymizationServiceImpl.java:255-258,393` |
| B13 | Medium | RPC replies default to a 5 s timeout; four call sites unbox `null` into a primitive | `AnimalSubjectServiceImpl.java:150`; `BrukerApiController.java:139`; `ImporterApiController.java:486`; `BIDSServiceImpl.java:444` |
| B14 | Medium | `PageImpl` mutators always throw `UnsupportedOperationException` | `PageImpl.java:60-96` |
| B15 | Medium | Shanoir `AccessDeniedException` returns 500 instead of 403; generic handler leaks internals | `GlobalExceptionHandler.java:46,59-69` |
| B16 | Medium | `@WithMockKeycloakUser` on a production `@RabbitListener` — no runtime effect | `shanoir-ng-datasets/.../DatasetAcquisitionApiController.java:150` |
| B17 | Medium | Security context fabricated 43× and cleared once ⇒ ADMIN leaks across pooled listener threads | `SecurityContextUtil.java:41-52` |
| B18 | Medium | Spring Boot's version *is* the backend artifact version; nine poms hardcode `3.4.0` | `shanoir-ng-back/pom.xml:20-31` |
| B19 | Medium | `Device Description (0050,0020)` silently dropped by the 10-char tag check | `AnonymizationRulesSingleton.java:87` |
| B20 | Medium | `ms_users_to_ms_studies_user_delete` has a publisher and no consumer — unbounded durable queue | `RabbitMQConfiguration.java:403`; `InterMicroservicesCommunicator.java:49` |
| B21 | Medium | S3 empty-prefix check uses `!=` on Strings; bucket creation failure is swallowed | `S3StorageService.java:528,544` |
| B22 | Medium | New `StudyUserRight` values throw on un-upgraded replicas, breaking all rights checks | `StudyUserRight.java:80` |
| B23 | Low | Overlay `(60xx,3000)` mis-routed to the overlay-comments action for groups ≠ 6000 | `AnonymizationServiceImpl.java:311-320` |
| B24 | Low | `MDCFilter` logs unauthenticated requests as `Admin` | `MDCFilter.java:31` |
| B25 | Low | `dateToLocalDate`/`localDateToDate` use different zones — round trip can shift a day | `DateTimeUtils.java:41,46` |
| B26 | Low | `Utils.toList` returns the caller's own list; `equalsIgnoreNull` NPEs on transient entities | `Utils.java:53-55,79` |
| B27 | Low | Six dead queue constants; four consumers with no publisher; `study-user` never bound | see §4.3 |
| B28 | Low | `TestTrustManager` (trust-all TLS) on the production classpath of six services | `utils/tests/TestTrustManager.java:19` |

### Detail on selected findings

**B1 — Remote unauthenticated administrative access via RabbitMQ.**
*What's wrong.* Three independent weaknesses compose. (i) `docker-compose.yml:74-83` publishes 5672 and 15672 on the host with the default `guest` account, which the official image permits from non-loopback addresses. (ii) No `MessageConverter` bean exists, so Spring's `SimpleMessageConverter` handles `application/x-java-serialized-object` bodies with no allow-list — reachable on the eight queues whose listener parameter is `Long`/`List<Long>` (§4.5). (iii) 43 listener methods begin with `SecurityContextUtil.initAuthenticationContext("ROLE_ADMIN")`.
*How it manifests.* Anyone with network access to the broker can drive any listener with administrator authority — e.g. publish a `StudyUserCommand[]` to `study-user-exchange` granting `CAN_ADMINISTRATE` on all studies, or attempt a deserialization gadget on `study-i-can-admin`.
*Fix.* Remove the host port mappings (use `expose`); create per-service RabbitMQ users with per-queue permissions and a dedicated vhost; register a `Jackson2JsonMessageConverter` (or set `allowedListPatterns`); upgrade off EOL 3.10.7; replace the fabricated ADMIN context with a narrow, per-listener service principal and always clear it in a `finally`.

**B2 — Compound action codes.**
*What's wrong.* `getFinalValueForTag` recognises exactly five single letters; the five compound codes defined in the workbook's own Legend fall through to `result = ""`.
*How it manifests.* 49 tags across the shipped profiles get zero-length values instead of removal, dummy substitution or UID re-mapping. `Referenced Image Sequence`/`Source Image Sequence` lose their UID linkage instead of being re-mapped. Numeric-VR tags throw `NumberFormatException` from `Integer.decode("")` (`:570`) — outside the `catch (IOException)` — aborting the batch after the output file has been opened for writing.
*Fix.* Resolve compound codes at load time in `AnonymizationRulesSingleton` against the tag's VR and IOD type, storing a single resolved action per (tag, profile). Reject unknown action strings at load time with a hard failure rather than defaulting to blank.

**B4 — Fail-open anonymization.**
*What's wrong.* `catch (final IOException exc) { LOG.error(...) }` at `:332-334`, with no rethrow and no per-file status returned to the caller.
*How it manifests.* A file that cannot be parsed keeps its original PHI and is imported. A file that fails mid-write is truncated, because `new DicomOutputStream(dicomFile)` at `:329` opens the *same* file for writing while it is still open for reading.
*Fix.* Write to `dicomFile + ".anon.tmp"` and `Files.move(..., ATOMIC_MOVE)` on success. Rethrow (or accumulate into a per-file result) so `anonymize()` can fail the import. Add a post-condition check that re-reads the output and asserts `PatientName`/`PatientID` equal the intended pseudonym.

**B6 — Out-of-order rights commands.**
*What's wrong.* The three `study-user-queue-*` listeners use `multipleConsumersFactory` (10 concurrent consumers).
*How it manifests.* Two rapid changes to the same `study_user` — grant then revoke — can be applied in reverse, leaving the replica with rights the master has revoked. No test, no ordering guarantee, no version column to detect it.
*Fix.* Switch these three listeners to `singleConsumerFactory` (they are low-volume), or add a monotonically increasing `version` to `StudyUserCommand` and discard stale commands on apply. Make `processCommands` `@Transactional`.

**B13 — RPC timeouts.**
*What's wrong.* Only `shanoir-ng-studies/application.yml:76-77` sets `template.reply-timeout`; everywhere else it is 5,000 ms, and `convertSendAndReceive` returns `null` on timeout.
*How it manifests.* `(boolean) rabbitTemplate.convertSendAndReceive(...)` throws `NullPointerException` on unboxing whenever the downstream service takes longer than 5 s — which for `anima-conversion-queue` (an image conversion) is the normal case.
*Fix.* Set an explicit `reply-timeout` per service sized to the slowest operation; use `Boolean.TRUE.equals(...)` / explicit null checks at every call site (the pattern already used at `DatasetDownloaderServiceImpl.java:316`); convert long-running RPCs to async request/reply with a correlation id, as `BidsValidationResultListener` already does.

**B14 — `PageImpl` mutators.**
*What's wrong.* `getContent()` on Spring Data's `Chunk` returns `Collections.unmodifiableList(content)`; all six overrides delegate to it.
*How it manifests.* Any caller invoking `page.add(...)` gets `UnsupportedOperationException`. The methods exist purely to satisfy the custom `Page` interface.
*Fix.* Remove the mutators from the `Page` interface, or hold a mutable backing list.

**B22 — Enum forward-compatibility.**
*What's wrong.* `StudyUserRight.getType` throws for unknown ids (`:80`), and it is on the hot path of every authorization check via `StudyUser.getStudyUserRights()`.
*How it manifests.* During a rolling upgrade, one row containing a new right id makes every rights check for that study throw — a self-inflicted outage.
*Fix.* Return `null` for unknown ids and filter them out in `getStudyUserRights()`; log once at WARN.

---

## 12. Security and data-protection review

**Authorization.**
- The ADMIN-context fabrication (`SecurityContextUtil.java:50-52`) plus the never-cleared context (§3.6) plus the exposed broker (§4.6) is the dominant risk. It converts message-queue access into platform administration.
- `@WithMockKeycloakUser(authorities = {"ROLE_ADMIN"})` on `DatasetAcquisitionApiController.java:150` is a **no-op at runtime**. The listener runs with whatever context the thread carries — which, given the leakage above, is non-deterministic. This is the worst combination: the code reads as if it were secured.
- `hasRightOnCenter` grants center access on the existence of a `study_user` row alone (`StudyRightsService.java:84-88`), without `isConfirmed()` and without any right.
- `ms-preclinical` consumes the shared messaging and elevation helpers but has **no `study-rights` dependency** at all — the rights model simply is not enforced there by this layer.
- `KeycloakUtil.getConnectedUserRoles()` returns an empty list for anonymous users rather than failing (`:87-89`).

**Anonymization / PHI (see §6 for the full analysis).** No `(0012,0062) Patient Identity Removed`. No sequence traversal. No pixel-data / burned-in-annotation handling. Private tags kept by default in both production profiles with only a literal-substring heuristic as protection. Dates, device identity and patient characteristics retained in OFSEP/Neurinfo without declaring the corresponding PS3.15 options. Failures are silent and fail-open.

**Unsafe deserialization.** `SimpleMessageConverter` with no allow-list on eight queues carrying `Long`/`List<Long>` (§4.5). Separately, `StudyUserCommand` deserialization mutates the shared mapper at runtime (§5.3) — not a gadget vector in itself, but it makes the mapper's deserialization configuration attacker-influenced in shape if not in content.

**Unverified JWT parsing.** `SecurityContextUtil.decodeJwtClaims` (`:81-91`) splits and base64-decodes a token with no signature check, and its output selects the `client_id` used against Keycloak (`KeycloakServiceAccountUtils.java:70`).

**Secrets and credentials.**
- `@Value("${service-account.client.credential-secret:'SECRET'}")` — a quoted literal default that ms-users does not override (`KeycloakServiceAccountUtils.java:51`).
- `guest`/`guest` in two `application.yml` files and in `docker-compose.yml:460`.
- No secret rotation story; no vault; the RabbitMQ management UI is published on the host.

**Transport.** `TestTrustManager` (`utils/tests/TestTrustManager.java:19`) accepts every certificate and ships on the production classpath of six services. Dead today; one careless import away from disabling TLS verification.

**Path traversal.** `FileSystemStorageService` `store`/`load` (`:214`, `:258-260`) — URL-decode then join, no normalisation, no containment check.

**PHI in logs.**
- `ShanoirEventService.publishEvent` logs the full event including `message` and `report` at INFO (`:47-56`). Import reports carry subject identifiers.
- `AnonymizationServiceImpl.recordAndTrace` logs `'oldValue' -> 'newValue'` at DEBUG (`:489-490`) — correctly documented as PHI-bearing (`:479-484`), but a single log-level change exposes patient names.
- `LOG.warn("Potential PHI found in private tag …" + value)` at `AnonymizationServiceImpl.java:410` logs the **suspected PHI value itself at WARN** — i.e. in default production logging.
- `RabbitMQStudiesService.java:280` logs the whole quality-tag message.
- `MDCFilter` labels unauthenticated requests `Admin` (`:31`), corrupting the audit trail.

**GDPR implications.**
1. Outputs of Profiles OFSEP/Neurinfo are **pseudonymised**, not anonymous (Recital 26) — retained dates + device identity + patient characteristics + un-scanned private tags. They remain in scope of the Regulation and must not be treated as freely shareable.
2. Article 32 (security of processing): the anonymization pipeline has no tests, no post-condition verification, and fails open. That is difficult to defend as "appropriate technical measures".
3. Article 5(1)(f) / Article 32 again: the broker exposure and the ADMIN elevation mean a single network position yields access to all patient data.
4. Pseudonym quality: unsalted SHA-1 over `firstName+lastName+birthDate` (`IdentifierCalculator.java:88-107`) is reversible by dictionary attack; EDPB guidance on pseudonymisation expects a keyed function with the key held separately.
5. Article 30 / auditability: `ShanoirEvent` is the audit record, but events are lost on broker outage (no outbox, no confirms) and the `MDCFilter` mislabels actors.
6. `LOG.warn` of suspected PHI (`:410`) writes patient identifiers into logs that are almost certainly outside the data-protection perimeter applied to the imaging store.

---

## 13. Technical debt inventory

| # | Item | Impact | Effort |
|---:|---|---|---|
| 1 | No DLQ / retry / confirms on 67 queues | Silent data and rights loss | 1–2 wks |
| 2 | No `MessageConverter` ⇒ Java deserialization | Remote code execution surface | 2 d |
| 3 | Anonymization untested & untestable in its current shape | Patient privacy | 2–3 wks |
| 4 | `study-rights` untested | Authorization | 1 wk |
| 5 | `storage` untested | Path traversal, data loss | 3 d |
| 6 | `keycloak-auth` untested | Login availability & correctness | 3 d |
| 7 | `study_user` replicated across 4 databases with no reconciliation | Divergent authorization state | 3–4 wks |
| 8 | Version inherited from Spring Boot; 9 hardcoded `3.4.0` | Build breaks on the next Boot upgrade | 1 d |
| 9 | `ms-common` is a 102-class grab-bag | Every change rebuilds every service | 3–4 wks |
| 10 | ~500 LOC dead + ~400 LOC test-only code in `src/main` | Confusion; `TestTrustManager` is a hazard | 1 d |
| 11 | 11 orphaned queues (6 dead, 4 publisher-less, 1 unbound) | Operator confusion; one grows forever | 1 d |
| 12 | `SecurityContextUtil` ADMIN elevation, never cleared | Privilege escalation | 1–2 wks |
| 13 | Rules in a binary `.xlsx` | The most safety-critical config is un-reviewable | 3 d (convert to CSV/YAML + parser test) |
| 14 | Four Java levels (11/17/17/21), three versioning schemes | Toolchain friction | 2 d |
| 15 | Jackson pinned to 2.13.4.1 in `exchange` | Stale transitive dependency | 1 d |
| 16 | Jacoco 0.7.9 (2017) — predates Java 9 | Coverage cannot be measured on Java 21 | 1 d |
| 17 | RabbitMQ 3.10.7 EOL; log4j-bom pinned to 2.17.1 | Unpatched infrastructure | 2 d |
| 18 | No tracing/correlation across queues | Cross-service failures undiagnosable | 1–2 wks |
| 19 | `@Profile("!test")` on the topology | Contract tests impossible | 1 d |
| 20 | Unsalted SHA-1 pseudonyms | Re-identification; fixing needs data migration | 2 wks + migration |

---

## 14. Improvement roadmap

### Quick wins (< 1 day each)

1. Delete `TestTrustManager`, `PageModule`, `PageDeserializer`, `UserWithId`, `Spring`. *(~250 LOC, zero risk.)*
2. Remove the `5672`/`15672` host port mappings from both compose files; use `expose`.
3. Register a `Jackson2JsonMessageConverter` bean in `ms-common`, or at minimum `simpleMessageConverter.setAllowedListPatterns(List.of("java.lang.*","java.util.*"))`.
4. Give `shanoir-ng-back` an explicit `<version>3.4.0</version>` and replace the nine hardcoded `3.4.0` dependency versions with `${project.version}`.
5. Fix `hasRightOnCenter`: move the null check before the dereferences and add the `isConfirmed()` + right checks its siblings have.
6. Fix the `!=` string comparison in `S3StorageService.ensureValidPrefix:528`.
7. Set an explicit `spring.rabbitmq.template.reply-timeout` in every service; replace the four `(boolean)` casts with `Boolean.TRUE.equals(...)`.
8. Remove `@WithMockKeycloakUser` from `DatasetAcquisitionApiController:150` and elevate explicitly.
9. Delete the six dead queue constants and the never-consumed `MS_USERS_TO_MS_STUDIES_USER_DELETE` (or add its consumer); delete the unbound `study-user` queue bean.
10. Change `LOG.warn` at `AnonymizationServiceImpl:410` to log the tag only, never the value.
11. Add `finally { SecurityContextUtil.clearAuthentication(); }` to every listener that elevates.
12. Move `registerModule` out of `receiveStudyUsers` into a `@Bean SimpleModule` (`RabbitMqStudyUserService:59-61`).
13. Fix `MDCFilter` to log `anonymous`, not `Admin`.
14. Upgrade Jacoco from 0.7.9 to 0.8.12 so coverage can actually be measured.

### Medium (1–2 weeks each)

15. **Anonymization golden-file harness** (§6.6) — build fixtures with dcm4che, one committed golden dump per profile.
16. **Implement compound action codes** and reject unknown actions at load time.
17. **Recurse into sequences** and implement the `K`-means-clean-sequences semantics the Legend already specifies.
18. **Make anonymization fail closed**: temp-file-and-rename, per-file result status, post-condition verification, rethrow on error.
19. **Set `(0012,0062)/(0012,0063)/(0012,0064)`** and declare the retained-information options for OFSEP/Neurinfo.
20. **Convert `anonymization.xlsx` to a reviewable text format** (CSV or YAML) with a parser test; keep the workbook as the editing front-end if the team prefers, but generate the text file in the build.
21. **`study-rights` test suite** + make `processCommands` transactional + single-consumer (or versioned) command application.
22. **DLQ everywhere**: one `x-dead-letter-exchange` per queue, a `shanoir.dlq` sink, an alert on non-empty DLQs, and a documented replay procedure.
23. **Storage path-safety**: a single `resolveWithin(base, untrusted)` helper that normalises and asserts containment, plus tests.
24. **`keycloak-auth` hardening**: `DateTimeFormatter` instead of `SimpleDateFormat`, a shared `CloseableHttpClient` with connect/socket timeouts, consume and close the response, and fail-closed when the admin IP list is unconfigured.

### Large (1–2 months each)

25. **Split `ms-common`** into `shanoir-contracts`, `shanoir-spring-support`, `shanoir-security`, `shanoir-test-support`; publish them as versioned artifacts on every merge to develop, not by manual `workflow_dispatch`.
26. **Contract testing across the bus.** Remove `@Profile("!test")`, add a Testcontainers RabbitMQ, and generate a test per (queue, publisher, consumer) triple asserting name, payload type and round-trip. Fail the build on an orphaned queue.
27. **Schema decoupling for `study_user`.** Replace the shared entity with a versioned snapshot DTO; give each service its own internal representation; add an outbox in ms-studies and a periodic reconciliation job so drift self-heals.
28. **Retire the fabricated ADMIN context.** Give each service a Keycloak service account with a narrow role set, and have listeners authenticate as that principal.

---

## 15. Future work and feature directions

1. **Typed event contracts with a schema registry.** `ShanoirEventType` + `RabbitMQConfiguration` + hand-written `objectMapper.writeValueAsString` is a hand-rolled, unversioned protocol. Define the events in JSON Schema (or Avro/Protobuf), generate the Java types, register them, and enforce backward compatibility in CI. This kills the "silently lossy rename" class of bug that `FAIL_ON_UNKNOWN_PROPERTIES=false` currently hides.
2. **Replace hand-rolled rights with a policy engine.** Six imperative methods in `StudyRightsService`, a replicated table in four databases, and a scattering of SpEL `@PreAuthorize` strings. A declarative model — OPA/Rego, Cedar, or Keycloak Authorization Services — would make the policy reviewable and testable in one place, and would remove the need to replicate `study_user` at all if backed by a rights-lookup service with a short-TTL cache.
3. **OpenTelemetry across HTTP and AMQP.** Propagate a trace context from nginx through every service and *through the queues* (`MessageProperties` headers), so a failed import is one trace instead of five log files. This also gives per-queue latency and error metrics, which today do not exist.
4. **Publish versioned artifacts automatically.** Semantic versioning independent of Spring Boot, published on merge, with the docker image tags referencing the same version. Add `japicmp` or `revapi` to fail the build on a breaking change to `shanoir-contracts`.
5. **An anonymization conformance suite** built from public de-identification test data (e.g. the DICOM WG-18 / TCIA test sets), run in CI, producing a published conformance statement that lists exactly which PS3.15 options Shanoir implements. For a platform used in OFSEP and Neurinfo this is a deliverable in its own right.
6. **Pixel-data de-identification.** Even a conservative implementation — detect `BurnedInAnnotation == YES`, detect secondary-capture SOP classes, and either reject or blank a configurable region — would close the largest remaining PHI channel.
7. **Keyed pseudonymisation.** Replace unsalted SHA-1 with HMAC-SHA-256 under a per-deployment key held outside the application database, with a documented key-rotation and re-linkage procedure.
8. **Outbox + reconciliation as a shared library capability.** Both `ShanoirEventService` and `StudyUserUpdateBroadcastService` need it; building it once in `shanoir-contracts` serves every future cross-service write.

---

## 16. Appendix

### A. Largest files in the shared layer

| LOC | File |
|---:|---|
| 736 | `shanoir-ng-storage/src/main/java/org/shanoir/ng/storage/S3StorageService.java` |
| 691 | `shanoir-ng-anonymization/src/main/java/org/shanoir/anonymization/anonymization/AnonymizationServiceImpl.java` |
| 593 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/configuration/RabbitMQConfiguration.java` |
| 426 | `shanoir-ng-storage/src/main/java/org/shanoir/ng/storage/FileSystemStorageService.java` |
| 313 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/utils/Utils.java` |
| 229 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/event/ShanoirEvent.java` |
| 201 | `shanoir-ng-study-rights/src/main/java/org/shanoir/ng/study/rights/StudyUser.java` |
| 201 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/email/EmailStudy.java` |
| 200 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/utils/KeycloakUtil.java` |
| 197 | `shanoir-ng-keycloak-auth/src/main/java/org/shanoir/ng/keycloak/authentication/ShanoirNgPostAuthAuthenticator.java` |
| 188 | `shanoir-ng-study-rights/src/main/java/org/shanoir/ng/study/rights/StudyRightsService.java` |
| 158 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/utils/assertion/AssertUtils.java` (test-only) |
| 150 | `shanoir-ng-anonymization/src/main/java/org/shanoir/anonymization/anonymization/AnonymizationRulesSingleton.java` |
| 145 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/dicom/EquipmentDicom.java` |
| 137 | `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/dicom/SerieToDatasetsSeparator.java` |
| 136 | `shanoir-ng-anonymization/src/test/java/org/shanoir/anonymization/anonymization/AnonymizationTest.java` (not a test) |

### B. TODO / FIXME / XXX / HACK inventory

The complete list for all six modules is **two entries**, both in the one module Checkstyle does not lint:

| Location | Marker | Text |
|---|---|---|
| `shanoir-ng-keycloak-auth/.../ShanoirNgPostAuthAuthenticatorFactory.java:54` | FIXME | "not clear (might mess up with required actions)" — on `isUserSetupAllowed()` |
| `shanoir-ng-keycloak-auth/.../ShanoirNgPostAuthAuthenticator.java:124` | FIXME | "the expirationDate in the keycloak db are not consistent: older entries are stored as a timestamp and newer entries are stored as 'YYYY-MM-DD'" |

This is **not** a sign of a clean codebase. `shanoir-ng-back/checkstyle.xml` enables the `TodoComment` module at `severity=error` (`:56`), so TODO markers are a build failure in the ten linted modules. The debt is real (see §13); it is simply undocumented in the source. There are, separately, plain-language markers the linter does not catch — e.g. `TEMPORARY CLASS. Used to test anonymization process.` on `SendToPacs.java:15-16` (a production-source class that hardcodes `DCM4CHEE@localhost:11112`), and the four `//todo:` lowercase comments in the `exchange` model classes.

### C. Dependency observations

| Dependency | Declared | Observation |
|---|---|---|
| `log4j-bom` | **2.17.1** (`shanoir-ng-back/pom.xml:63-70`) | Dec 2021. Pinned to override Spring Boot's managed version, so this is a **downgrade** relative to Boot 3.4's dependency management. Post-Log4Shell fixes have shipped since; the pin should be removed or moved forward. |
| `jacoco-maven-plugin` | **0.7.9** (`shanoir-ng-parent/pom.xml:66-68`) | 2017 — predates Java 9. Cannot instrument Java 21 bytecode. Coverage reporting is effectively non-functional. |
| `jackson` | **2.13.4.1** (`shanoir-ng-exchange/pom.xml:38`) | Oct 2022; overrides nothing for modules with Boot's `dependencyManagement`, but is the effective version for `exchange` itself and possibly `shanoir-uploader`. |
| `mockito-core` | **3.4.0** (`shanoir-ng-exchange/pom.xml:93-97`) | 2020. Tests use the deprecated `org.mockito.runners.MockitoJUnitRunner` (still present in 3.4.0, so they compile). |
| `junit` | **4.12** (`exchange`), **4.13.1** (`anonymization`) | The rest of the platform is on JUnit 5. `DateTimeUtilsTest` is JUnit 5; `IdentifierCalculatorTest` is JUnit 4. |
| `rabbitmq` | **3.10.7** (`docker-compose.yml:76`) | End of life. |
| `poi` / `poi-ooxml` | 5.4.0 | Current; pulled in *only* to parse the anonymization workbook. Converting the rules to CSV/YAML would drop POI and its transitive tree from ms-import and ShanoirUploader. |
| `httpclient` | 4.5.13 (`keycloak-auth`) | Apache HttpClient 4.x is in maintenance; 5.x is current. |
| `ipaddress` | 5.3.3 (`keycloak-auth`) | Fine. |
| `spring-cloud-aws-starter-s3` | 3.4.0 (`shanoir-ng-storage/pom.xml:41-45`) | Fine. |
| `spring-boot-starter-test` | compile scope, **not** `test` (`shanoir-ng-back/pom.xml:117-121`) | Deliberate ("do not put scope test here: compile errors: org.json package will be missing"). Consequence: **JUnit, Mockito, AssertJ, Hamcrest and `spring-security-test` ship inside every production container.** Same for `spring-security-test` at `:143-147`. This is what allows `@WithMockKeycloakUser` to be imported in production code (§12) without a compile error. |

### D. Checkstyle notes

`shanoir-ng-back/checkstyle.xml` runs at `severity=error` (`:56`) with ~50 modules, including `MagicNumber`, `MissingJavadocMethod`, `TodoComment`, `VisibilityModifier` and `UnusedImports`.

`shanoir-ng-back/suppressions.xml` is short and reasonable — `MethodName` for Spring Data repositories, `Header` for the vendored EEG EDF/BrainVision parsers, `FinalClass`/`HideUtilityClassConstructor` for `*Application.java`.

Two gaps worth noting:

1. **`shanoir-ng-storage` and `shanoir-ng-keycloak-auth` are absent from the Checkstyle workflow's module list** (`.github/workflows/checkstyle.yml:56-67`), which covers ten modules. The two modules with zero tests and the two `FIXME`s are also the two that are not linted.
2. `maven.yml` builds with `-Dcheckstyle.skip=true` (`:56`), so style is only enforced by the separate workflow — which invokes `checkstyle:check` per module with `-Dcheckstyle.config.location` but **without** `-Dcheckstyle.suppressions.file`. Whether the suppressions still apply depends on the `checkstyle.suppressions.file` property inheriting from `shanoir-ng-back/pom.xml:57` in a `-pl` build *(inferred; not verified by running Maven)*.

`UnusedImports` is enabled at error severity, yet `S3StorageService.java` carries a duplicate `import java.util.Arrays;` (`:422`, `:428`) and roughly eight unused imports — consistent with `shanoir-ng-storage` not being covered by the workflow.

---

*Prepared from a static read of the tree at `867e53290`. No code was modified and no build was executed. Claims marked "(inferred)" were not verified at runtime.*
