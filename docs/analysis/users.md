# `shanoir-ng-users` — Engineering Audit

Static audit of the Shanoir-NG identity / account-lifecycle / audit-log microservice.
Repository `fli-iam/shanoir-ng`, HEAD `867e53290`, version 3.4.0. No code was executed; every
claim below is traceable to a `path:line` citation. Where I infer runtime behaviour rather than
read it, I say so explicitly.

---

## 1. Executive summary

`shanoir-ng-users` is the platform's identity provider mirror, account-lifecycle workflow engine,
outbound e-mail gateway, and — unexpectedly — the **sole consumer and store of the platform-wide
audit event stream**. It is the smallest of the three "big" services (8,680 main LOC / 80 classes,
3,645 test LOC / 22 classes) but it carries the highest concentration of trust decisions in the
whole system.

**Health verdict: at risk.** The core user CRUD path is reasonably well guarded by a
defence-in-depth pattern (`@PreAuthorize` on both the controller interface *and* the service
interface, plus reflective `@EditableOnlyBy` / `@VisibleOnlyBy` field guards). But three whole
API surfaces were added later without that discipline (`AccessRequestApi`, `EventsApi`,
`RoleApi` carry **zero** `@PreAuthorize` annotations), the Keycloak dual write has no rollback or
reconciliation whatsoever, and the event log is a mutable, upsertable, silently-lossy table that
should not be relied on as a medical-data audit trail.

Top findings, ranked:

| # | Severity | Finding | Anchor |
|---|----------|---------|--------|
| 1 | **Critical** | `AccessRequestApi` has no authorization annotations at all. Any authenticated `ROLE_USER` can approve any pending study access request (`PUT /accessrequest/resolve/{id}` with body `true`), which publishes a `study-subscription-queue` message that makes the studies service grant study data access. | `accessrequest/controller/AccessRequestApi.java:73`, `AccessRequestApiController.java:170-201` |
| 2 | **Critical** | Any authenticated user can read any other user's full record (e-mail, names, role) by guessing a username via `PUT /accessrequest/invitation/`. `findByUsernameForInvitation` is deliberately opened to `ROLE_USER` and the response embeds the whole `User` entity, bypassing the `@PostAuthorize` privacy filter. | `AccessRequestApiController.java:238-261`, `user/service/UserService.java:121` |
| 3 | **High** | JPQL injection: the `searchField` request parameter and every `Pageable` sort property are string-concatenated into a JPQL query on the events (audit) table. | `events/ShanoirEventRepositoryImpl.java:72-74`, `:98-100` |
| 4 | **High** | The audit log is not append-only. `ShanoirEvent.id` is a producer-chosen random long with no `@GeneratedValue`, so `repository.save()` is an **upsert**: any service (or anything that can publish to `events-exchange`) can silently overwrite an existing audit record by reusing its id. | `events/ShanoirEventLight.java:38-39`, `events/ShanoirEventsService.java:59` |
| 5 | **High** | Audit events are permanently dropped on any failure. `receiveEvent` throws `AmqpRejectAndDontRequeueException` and **no queue in the platform has a dead-letter exchange or retry policy**, so a users-DB outage silently destroys every audit event produced platform-wide during the outage. | `configuration/amqp/RabbitMQUserService.java:78-81`, `shanoir-ng-ms-common/.../RabbitMQConfiguration.java:41-60` |
| 6 | **High** | Keycloak dual write has no transaction, no compensation and no reconciliation. `create()` commits the DB row, then calls Keycloak; on failure the DB keeps a user with `keycloak_id = NULL`. `deleteById()` deletes the DB row first and swallows Keycloak delete failures, leaving orphaned Keycloak accounts. | `user/service/UserServiceImpl.java:279-304`, `:135-157`, `user/utils/KeycloakClient.java:322-328` |
| 7 | **High** | Fully rendered e-mail bodies are written to the application log at `INFO` (8 call sites), including subject names, examination ids, study names, user names and e-mail addresses. Combined with `ShanoirEventService`'s full event dump, this is a GDPR-relevant PII/PHI leak into a shared `logs` docker volume. | `email/EmailServiceImpl.java:180,203,503,543,578,599,631,713` |
| 8 | **Medium** | SpEL operator-precedence bug in `UserApi.updateUser`'s `@PreAuthorize` means the `idMatches(#userId, #user)` guard is *not* applied to admins — an admin `PUT /users/5` can update user 9, and the URL recorded by nginx will not match the row that changed. | `user/controller/UserApi.java:153` |

Positives worth stating: the service-layer `@PreAuthorize` net (`UserService.java:49-231`) is a
genuinely good second line of defence and it is exercised by a real test
(`UserServiceSecurityTest`); mass-email HTML escaping is done correctly
(`EmailServiceImpl.java:801` + `templates/massEmail.html:21`); Keycloak listing is paginated
rather than N+1 (`KeycloakClient.java:279-296`); and there is not a single `TODO`/`FIXME`/`XXX`/
`HACK` in the module.

---

## 2. Purpose & domain responsibilities

The service owns five distinct domains that have accreted into one deployable:

1. **User & role registry.** The `users` / `role` tables are the system of record for Shanoir user
   identity (`user/`, `role/`). Every other microservice refers to users by the numeric `userId`
   carried in the Keycloak token's `userId` claim (`shanoir-ng-ms-common/.../KeycloakUtil.java:47`).
2. **Account lifecycle.** Self-service account request (`accountrequest/`), admin
   confirm/deny (`UserServiceImpl.java:103-189`), account expiry with two warning e-mails and a
   Keycloak deactivation sweep (`scheduling/ScheduledTasks.java:56-90`), and expiry extension
   requests (`extensionrequest/`).
3. **Study access requests.** `accessrequest/` — a user asks to join a study, a study
   administrator approves, the approval is pushed to the studies service over AMQP.
4. **Outbound e-mail.** 25 live Thymeleaf templates + 4 dead ones (`resources/templates/`), driven
   both by local workflows and by six AMQP mail queues fed by `studies` and `datasets`. Plus a
   mass-mailing feature (`email/MassEmail*`) added in the most recent commits.
5. **Event log / async task tracker.** `events/` + `tasks/` consume `shanoir-events-queue`, persist
   to the `events` table, expose it per-study to study admins, and stream progress to the Angular
   front end over SSE.

Domains 4 and 5 have no intrinsic relationship to identity. They live here because this service
already had an SMTP client and a database (a rationale stated explicitly for the CLI tooling at
`ShanoirUsersManagement.java:57-61`).

---

## 3. Architecture & code structure

### 3.1 Package tree

```
org.shanoir.ng                          2 files    315 LOC   app entry + Keycloak sync CLI runner
├── accessrequest/controller            4 files    547 LOC   API + service impl (no authz)
│   ├── model                           1 file     101 LOC
│   └── repository                      1 file      32 LOC
├── accountrequest/controller           2 files    129 LOC   public self-service signup
│   ├── model                           1 file     105 LOC
│   └── repository                      1 file      30 LOC
├── configuration                       1 file      46 LOC   @Async executor for mass mail
│   ├── amqp                            2 files    243 LOC   all RabbitMQ listeners
│   └── security                        1 file     107 LOC   resource-server + CORS
├── email                               6 files  1,426 LOC   largest package
│   └── model                           3 files    189 LOC
├── events                              9 files    862 LOC   audit log store + query
├── extensionrequest/controller         2 files    118 LOC
│   └── model                           1 file      94 LOC
├── messaging                           1 file      56 LOC   Spring event -> AMQP bridge
├── role/{controller,model,repository,service}  8 files 369 LOC
├── scheduling                          1 file      92 LOC   daily expiry cron
├── shared/{controller,error,exception,validation}  8 files 512 LOC
├── tasks                               3 files    209 LOC   SSE emitters + task API
├── user/controller                     4 files    454 LOC
│   ├── model (+dto, +vip)              6 files    879 LOC
│   ├── repository                      1 file     113 LOC
│   ├── security                        3 files    164 LOC
│   ├── service                         5 files    858 LOC
│   └── utils                           1 file     385 LOC   KeycloakClient
└── utils                               2 files    245 LOC
                                       80 files  8,680 LOC
```

### 3.2 Layering

The nominal layering is `*Api` (interface: routing + Swagger + `@PreAuthorize`) → `*ApiController`
(`@Controller`) → `*Service` (interface: second `@PreAuthorize`) → `*ServiceImpl` → Spring Data
repository. It is followed for `user` and `role`. It is **not** followed elsewhere:

- `AccessRequestServiceImpl` lives in the `controller` package
  (`accessrequest/controller/AccessRequestServiceImpl.java:15`). Its interface carries exactly one
  `@PreAuthorize`, on `deleteById` (`AccessRequestService.java:38`) — a method that is not exposed
  over REST; the methods that *are* reachable (`update`, `createAllowed`, `findById`,
  `findByStudyIdAndStatus`) have none.
- `AccessRequestApiController` is a fat controller: it holds the AMQP template, the object mapper,
  the study-rights repository and the event service, and orchestrates the whole approval workflow
  in the controller method (`AccessRequestApiController.java:170-211`). There is no service layer
  for it at all.
- `ExtensionRequestApiController` injects `KeycloakClient` directly and performs a password reset
  from the controller (`extensionrequest/controller/ExtensionRequestApiController.java:59`).
- `ShanoirUsersManagement` is simultaneously an `ApplicationRunner` for a one-shot CLI migration
  **and** the Spring bean referenced by `@PreAuthorize("@shanoirUsersManagement.hasRightOnStudy(...)")`
  (`ShanoirUsersManagement.java:77`, `:273`; referenced from `events/EventsApi.java:45` and
  `email/MassEmailApi.java:67`). A migration tool and an authorization helper should not be the
  same bean.

`spring.main.allow-circular-references: true` (`application.yml:47`) papers over at least one bean
cycle; it should be removed and the cycle broken.

### 3.3 JPA entity model & owned schema

Database `users` (MariaDB), `ddl-auto: validate` in production (`application.yml:36`), schema owned
by the external `database-migrations` container.

| Entity | Table | Base class | Notes |
|---|---|---|---|
| `User` | `users` | `HalEntity` → `AbstractEntity` (`@GeneratedValue(IDENTITY)`) | `@OneToOne(orphanRemoval=true) AccountRequestInfo`, `@ManyToOne Role`, `@Embedded ExtensionRequestInfo`; implements Spring Security `UserDetails` |
| `Role` | `role` | `AbstractEntity` | implements `GrantedAuthority`; seeded 1=ADMIN, 2=USER, 3=EXPERT (`scripts/import.sql:15-20`) |
| `AccountRequestInfo` | `account_request_info` | `AbstractEntity` | contact / function / institution / studyId / studyName |
| `AccessRequest` | `access_request` | `AbstractEntity` | `@ManyToOne User`, `status` int (-1/0/1) |
| `ShanoirEvent` | `events` | `ShanoirEventLight` (`@MappedSuperclass`) | **`@Id` with no `@GeneratedValue`** — see §6 |
| `StudyUser` | (from `shanoir-ng-study-rights`) | — | local read-model replica of study rights |

Entity-model defects:

- **No `equals`/`hashCode` anywhere.** `AbstractEntity`
  (`shanoir-ng-ms-common/.../shared/core/model/AbstractEntity.java:29-53`) defines neither. The
  codebase works around this with `Utils.equalsIgnoreNull`, which special-cases `AbstractEntity`
  and compares ids (`shanoir-ng-ms-common/.../utils/Utils.java:78-80`). That workaround is what
  makes the `@EditableOnlyBy` role check actually function — a fragile coupling that is not
  documented at either site.
- `User.getAuthorities()` returns `Arrays.asList(role)` (`user/model/User.java:439`), so the entity
  doubles as a `UserDetails`. It is never used as one at runtime (the resource server builds
  `SimpleGrantedAuthority` from the JWT at `configuration/security/SecurityConfiguration.java:86`);
  `UserDetails` implementation on the JPA entity is dead weight.
- `User.isEnabled()` is derived from `expirationDate` only (`user/model/User.java:468-470`) and is
  used to compute the Keycloak `enabled` flag (`KeycloakClient.java:378`). It ignores the Keycloak
  `enabled` flag that admins can now set independently — see §5.4.
- `@Transient Boolean twoFactorEnabled` / `keycloakEnabled` on the entity
  (`user/model/User.java:77-86`) make the JPA entity a partial DTO for Keycloak state. There *is* a
  `user/model/dto/UserDTO.java` but it is not used on this path.

---

## 4. External interfaces

### 4.1 REST API

Exposed through nginx at `/shanoir-ng/users/` → `shanoir-ng-users:9900`
(`shanoir-ng-nginx/files/etc/nginx/nginx.conf:125`). Unless stated otherwise every route requires a
valid Keycloak JWT (`SecurityConfiguration.java:79-80`).

Anonymous (`permitAll`) routes, `SecurityConfiguration.java:76`:
`/accountrequest`, `/extensionrequest`, `/last_login_date`, `/users/count`, `/events/count`.

| Method | Path | Authorization | Purpose |
|---|---|---|---|
| GET | `/users` | `hasAnyRole('ADMIN','EXPERT')` + `@PostAuthorize` privacy filter | list all users (unbounded) |
| GET | `/users/{userId}` | `ADMIN` or self | read one user (+2 Keycloak calls for admins) |
| POST | `/users` | `hasRole('ADMIN')` | create user; service also requires `#user.getId() == null` |
| PUT | `/users/{userId}` | see §9.8 — precedence bug | update user |
| DELETE | `/users/{userId}` | `ADMIN` and not self | delete user (DB + Keycloak + AMQP) |
| PUT | `/users/{userId}/confirmaccountrequest` | `ADMIN` and `idMatches` | approve account/extension request |
| DELETE | `/users/{userId}/denyaccountrequest` | `hasRole('ADMIN')` (service allows `EXPERT`) | deny + delete user |
| GET | `/users/accountRequests` | `ADMIN`/`EXPERT` + privacy filter | pending requests |
| POST | `/users/search` | `USER`/`ADMIN`/`EXPERT` | id list → `IdName` list |
| GET | `/users/count` | **none, anonymous** | active user count |
| POST | `/accountrequest` | **none, anonymous** | self-service signup |
| POST | `/extensionrequest` | **none, anonymous** | request expiry extension **and force a Keycloak password reset** |
| POST | `/last_login_date` | **none, anonymous** | set `last_login` for an arbitrary username |
| GET | `/roles` | **none beyond authenticated** (`role/controller/RoleApi.java:39`) | list roles |
| POST | `/accessrequest` | **none beyond authenticated** | create study access request |
| PUT | `/accessrequest/resolve/{id}` | **none beyond authenticated** | approve/refuse — see §9.1 |
| GET | `/accessrequest/byAdmin` | **none beyond authenticated** | requests for studies I administrate |
| GET | `/accessrequest/byUser` | **none beyond authenticated** | my requests |
| GET | `/accessrequest/byStudy/{studyId}` | **none beyond authenticated** | all pending requests of *any* study |
| GET | `/accessrequest/{id}` | **none beyond authenticated** | read *any* access request (IDOR) |
| PUT | `/accessrequest/invitation/` | **none beyond authenticated** | invite by e-mail or username — see §9.2 |
| GET | `/events/{studyId}` | `ADMIN` or `CAN_ADMINISTRATE` on study | paged, searchable audit log |
| GET | `/events/count?days=N` | **none, anonymous** | event count |
| GET | `/tasks` | `ADMIN`/`EXPERT`/`USER` | my async tasks (last 7 days) |
| GET | `/tasks/{taskId}` | `ADMIN`/`EXPERT`/`USER`, scoped by `findByIdAndUserId` | task detail |
| GET | `/tasks/updateTasks` | **none beyond authenticated** (`tasks/AsyncTaskApi.java:72`) | open an SSE stream |
| GET | `/massemail/count?group=` | `hasRole('ADMIN')` | count recipients |
| POST | `/massemail` | `ADMIN`, or study `CAN_ADMINISTRATE` for `STUDY` group | send mass e-mail |

Several `@GetMapping`s declare `consumes = {"application/json"}`
(`AccessRequestApi.java:85-86,96-97,107-108,120-121`), which forces clients to send a
`Content-Type` header on a GET or receive 415. It works with the Angular client but is wrong.

### 4.2 RabbitMQ — exact queue inventory

All queue constants are in `shanoir-ng-ms-common/src/main/java/org/shanoir/ng/shared/configuration/RabbitMQConfiguration.java`.

**Consumed (inbound listeners in this service):**

| Queue / binding | Exchange | Payload | Producer(s) | Handler |
|---|---|---|---|---|
| `shanoir-events-queue` (key `*.event`) | `events-exchange` (topic) | `ShanoirEvent` JSON | `studies`, `datasets`, `users` (all via `ShanoirEventService`) | `RabbitMQUserService.java:73` |
| `study-user-queue-users` | `study-user-exchange` (fanout) | `StudyUserCommand[]` JSON | `studies` (`StudyUserUpdateBroadcastService.java:44`) | `RabbitMQUserService.java:59` |
| `import-dataset-mail-queue` | default | `EmailDatasetsImported` JSON | `datasets` (`ImporterMailService.java:89`) | `RabbitMQUserService.java:90` |
| `import-dataset-failed-mail-queue` | default | `EmailDatasetImportFailed` JSON | `datasets:103`, `import` (`ImporterManagerService.java:273`) | `RabbitMQUserService.java:108` |
| `study-user-mail-queue` | default | `EmailStudyUsersAdded` JSON | `studies` (`StudyServiceImpl.java:785`) | `RabbitMQUserService.java:126` |
| `draft-study-mail-queue` | default | `EmailStudy` JSON | `studies` (`StudyServiceImpl.java:799`) | `RabbitMQUserService.java:139` |
| `approve-study-mail-queue` | default | `EmailStudy` JSON | `studies` (`StudyServiceImpl.java:815`) | `RabbitMQUserService.java:152` |
| `dua-draft-mail-queue` | default | `DuaDraftWrapper` JSON | `studies` (`DuaDraftAPIController.java:121`) | `RabbitMQUserService.java:169` |
| `execution-monitoring-task` (**RPC**) | default | `Long` objectId → JSON `List<ShanoirEvent>` | `datasets` (`ExecutionMonitoringResumptionRunner.java:87`) | `RabbitMQEventService.java:50` |

**Published (outbound from this service):**

| Queue / exchange | Kind | Payload | Consumer | Call site |
|---|---|---|---|---|
| `events-exchange` (routing key = event type, e.g. `deleteUser.event`) | topic publish | `ShanoirEvent` JSON | itself (`shanoir-events-queue`) | via `ShanoirEventService.publishEvent`, called at `UserServiceImpl.java:150,366` and `AccessRequestApiController.java:118,250` |
| `delete-user-queue` | fire-and-forget | `ShanoirEvent` JSON | `studies` (`StudyUserServiceImpl.java:105`) | `UserServiceImpl.java:151` |
| `ms_users_to_ms_studies_user_delete` | fire-and-forget | `Long` userId | *(no listener found in the repo — see §9.14)* | `messaging/InterMicroservicesCommunicator.java:49` |
| `study-subscription-queue` | **RPC** (`convertSendAndReceive`) | `ShanoirEvent` JSON | `studies` (`RabbitMQStudiesService.java:233`) | `AccessRequestApiController.java:201` |
| `study-name-queue` | **RPC** | `Long` studyId → `String` | `studies` (`RabbitMQStudiesService.java:207`) | `AccessRequestApiController.java:110`, `UserServiceImpl.java:325`, `MassEmailServiceImpl.java:115` |
| `study-admin-queue` | **RPC** | `Long` studyId → `List<Long>` | `study-rights` (`RabbitMqStudyUserService.java:82`) | `EmailServiceImpl.java:647` |
| `study-i-can-admin` | **RPC** | `Long` userId → `List<Long>` | `study-rights` (`RabbitMqStudyUserService.java:70`) | `AccessRequestApiController.java:153` |

`shanoir-events-queue-import` is declared in `RabbitMQConfiguration.java:178,415` but no
`@RabbitListener` anywhere binds it — dead configuration.

**No queue in the platform declares `x-dead-letter-exchange`, and neither container factory sets
a retry advice chain or `defaultRequeueRejected`** (`RabbitMQConfiguration.java:41-60`). Consequences
in §6.3 and §9.5.

### 4.3 Keycloak admin API usage

Admin client built lazily with `Keycloak.getInstance(url, "master", SHANOIR_KEYCLOAK_USER,
SHANOIR_KEYCLOAK_PASSWORD, "admin-cli")` (`KeycloakClient.java:94-100`,
`ShanoirUsersManagement.java:175-185`) — i.e. **the realm-master super-admin credentials**, not a
scoped service account. Operations used:

| Operation | Method | Site |
|---|---|---|
| `users().create()` + `resetPassword` + `roles().realmLevel().add()` | create user | `KeycloakClient.java:112-139` |
| `users().get(id).resetPassword()` | force temp password | `KeycloakClient.java:146-159` |
| `users().get(id).update()` + realm-role swap | update user | `KeycloakClient.java:336-358` |
| `users().delete(id)` | delete user | `KeycloakClient.java:322-328` |
| `toRepresentation()/update()` on `requiredActions` + `credentials()`/`removeCredential` | TOTP enable/disable/read | `KeycloakClient.java:182-250` |
| `toRepresentation()/update()` on `enabled` | activate/deactivate | `KeycloakClient.java:261-270`, `:306-313` |
| `users().list(first, 100)` paginated | bulk enabled-status read | `KeycloakClient.java:279-296` |
| `users().search(username)` | migration existence check (**fuzzy — bug, §9.7**) | `ShanoirUsersManagement.java:191` |
| `users().searchByUsername(name, true)` | VIP service-account lookup (exact — correct) | `ShanoirUsersManagement.java:250` |

The service is also an OAuth2 **resource server** validating tokens against
`${SHANOIR_KEYCLOAK_URL}/realms/shanoir-ng` (`application.yml:84-85`).

### 4.4 SMTP / e-mail side effects

Spring `JavaMailSender`, host/port from env (`application.yml:69-79`), 29 Thymeleaf templates.
**All sends are synchronous on the calling thread** except mass e-mail. `EmailService` has no
`@Async` annotation anywhere (`email/EmailService.java`), so `mailSender.send(...)` blocks the HTTP
request thread inside `UserServiceImpl.create()` (`:302`), `createAccountRequest()` (`:338,343`),
`confirmAccountRequest()` (`:122,129`), `denyAccountRequest()` (`:180,187`) and
`requestExtension()` (`:275`) — several of those send **two** e-mails
(`EmailServiceImpl.java:232-253`).

Four templates are never referenced from Java: `notifyAdminAccountRequest.html`,
`notifyAdminStudyApproval.html`, `notifyUserAccessRequestAccepted.html`,
`notifyUserAccessRequestDenied.html`. `notifyAdminAccountRequest.html:26-29` reads
`user.accountRequestInfo.service/.study/.work/.challenge`, none of which exist on
`AccountRequestInfo.java:36-45` — proof the template is stale. The two access-request templates
being dead means **an approved study access request sends the user no e-mail**, while a refusal
does (`EmailServiceImpl.java:700-719`).

### 4.5 Shared `ms-common` / `study-rights` dependencies

Consumed from `shanoir-ng-ms-common`: `RabbitMQConfiguration`, `ShanoirEvent`, `ShanoirEventService`,
`ShanoirEventType`, `KeycloakUtil`, `SecurityContextUtil`, `Utils`, `MDCFilter`, `AbstractEntity`,
`HalEntity`/`Links`, `IdName`/`IdList`, `FieldErrorMap`/`ErrorModel`/`ErrorDetails`/
`RestServiceException` and the whole exception hierarchy, `@Unique` + `UniqueConstraintManagerImpl`,
`@EditableOnlyBy`/`@VisibleOnlyBy` + `FieldEditionSecurityManagerImpl`, `ControllerSecurityService`,
`KeycloakServiceAccountUtils`, `PageImpl`, `LocalDateAnnotations`, and the e-mail payload DTOs
(`EmailDatasetsImported`, `EmailDatasetImportFailed`, `EmailStudyUsersAdded`, `EmailStudy`,
`StudyInvitationEmail`, `DuaDraftWrapper`).

From `shanoir-ng-study-rights` (a jar dependency, `pom.xml:61-65`): `StudyUser`,
`StudyUserRightsRepository`, `StudyRightsService`, `RabbitMqStudyUserService`. This means the users
service embeds a **local replica of the study-rights table**, kept in sync by the
`study-user-queue-users` fanout binding. `MassEmailServiceImpl.resolveStudyRecipients` reads that
replica directly (`MassEmailServiceImpl.java:86`) — if the replica is stale, a study mass e-mail
goes to the wrong recipient set with no error.

Note the `ShanoirEvent` name collision: `org.shanoir.ng.shared.event.ShanoirEvent` (the AMQP DTO,
ms-common) vs `org.shanoir.ng.events.ShanoirEvent` (the JPA entity, local). Both are used in the
same service; `UserServiceImpl` imports the former, `ShanoirEventsService` the latter. This is a
real readability hazard.

---

## 5. Identity & Keycloak integration deep-dive

### 5.1 The dual-write model

Shanoir keeps user identity in **two** stores with no distributed transaction:

- MariaDB `users` table — numeric `id`, profile, role FK, expiry, workflow flags.
- Keycloak realm `shanoir-ng` — credentials, TOTP, `enabled`, realm role, plus custom attributes
  `userId`, `canImportFromPACS`, `expirationDate` (`KeycloakClient.java:367-373`).

The link is `users.keycloak_id` (DB → KC) and the `userId` attribute (KC → DB), the latter being
mapped into the JWT and read by every microservice.

### 5.2 Write paths and their failure modes

| Path | Order | Failure behaviour |
|---|---|---|
| `create()` `UserServiceImpl.java:279-304` | DB save → KC create → DB save (kcId) → KC enableTotp → e-mail | No `@Transactional`. Each `save()` commits independently. KC failure → `SecurityException` → HTTP 500, but **the DB row is already committed with `keycloak_id = NULL`**. The javadoc at `UserService.java:163-164` explicitly promises "In this case the user is not saved in the database either" — that promise is false. |
| `createAccountRequest()` `:307-345` | DB save (info) → DB save (user) → AMQP RPC → DB save (accessRequest) → **e-mail** → KC create → DB save (kcId) → e-mail | Same, plus the study-manager notification is sent *before* the Keycloak account exists. A KC failure leaves a DB user, a dangling `AccessRequest`, and an admin who was told to expect a signup that half-exists. |
| `update()` `:360-394` | publish audit event → KC TOTP → DB save → KC update → KC setEnabled | `keycloakClient.updateUser` swallows every exception (`KeycloakClient.java:355-357`), so a Keycloak role change can silently fail while the DB role changes. **Role divergence between DB and token is undetectable.** |
| `deleteById()` `:135-157` | delete access requests → delete DB row → Spring event → audit event + AMQP → **KC delete last** | `deleteUser` catches and logs everything (`KeycloakClient.java:325-327`). A KC outage leaves an orphaned, still-loginable Keycloak account whose `userId` attribute points at a deleted row. |
| `denyAccountRequest()` `:169-180` | delete DB row → KC delete → e-mail | Same orphan risk. |
| Migration sweep `ShanoirUsersManagement.createUsersIfNotExisting()` | per-user, best-effort, retried 50× | Uses fuzzy `search()` — see §9.7. |

### 5.3 What is missing

- **No reconciliation job.** Nothing ever scans for `keycloak_id IS NULL`, for Keycloak users with
  no matching DB row, or for role divergence. `getUsersEnabledStatus()`
  (`KeycloakClient.java:279-296`) proves a bulk read is cheap and already implemented — a nightly
  drift report would be a small addition.
- **No outbox.** The correct pattern here is: commit the DB row inside a transaction together with
  an outbox record, then drive Keycloak from the outbox with retries.
- **No idempotency on Keycloak create.** A retry after a partial failure will hit Keycloak's
  duplicate-username 409, which `KeycloakShanoirUtil.getCreatedUserId` turns into a
  `WebApplicationException` (`utils/KeycloakShanoirUtil.java:49-50`).
- **No `@Transactional` on any write method of `UserServiceImpl`.** Every `save()` runs in its own
  `SimpleJpaRepository` transaction. `deleteById` therefore cannot roll back its access-request
  deletions if the user delete fails.

### 5.4 Token & role mapping

Roles: DB `role.name` (`ROLE_ADMIN`/`ROLE_USER`/`ROLE_EXPERT`) is pushed to Keycloak as a **realm
role** of the same name (`KeycloakClient.java:126-131`), and the resource server converts
`realm_access.roles` straight into `SimpleGrantedAuthority`
(`SecurityConfiguration.java:83-88`). So `hasRole('ADMIN')` matches the `ROLE_ADMIN` realm role.

`updateUser` removes *all* realm roles whose names appear in the local `role` table, then adds the
new one (`KeycloakClient.java:341-354`) — a non-atomic remove/add. If the process dies between the
two, the user ends up with **no** Shanoir realm role and `realmAccess.get("roles")` in
`SecurityConfiguration.java:84` will return an empty/absent collection. Note that
`SecurityConfiguration.java:83-84` does not null-check `realm_access`, so a token without that
claim causes an NPE inside the JWT converter (500 rather than 401).

The `enabled` flag has two independent sources that fight each other: `getUserRepresentation`
computes `enabled = isEnabled() && !accountRequestDemand` from the DB
(`KeycloakClient.java:378`), and admins can set it explicitly. `UserServiceImpl.update` works
around this by reapplying the admin's choice *after* `updateUserOnAllSystems`
(`:383-391`) — an explicit, commented acknowledgement of the race. But
`ScheduledTasks.checkExpirationDate` calls `keycloakClient.updateUser(userToExpire)` directly
(`scheduling/ScheduledTasks.java:86`), which **silently re-derives and overwrites the admin's
manual activation choice every morning at 08:00** for any user in the expiry window. That is a
real, undocumented interaction.

---

## 6. Event log / audit trail deep-dive

### 6.1 How it works

Producers across the platform build a `ShanoirEvent`
(`shanoir-ng-ms-common/.../shared/event/ShanoirEvent.java:58-77`) and call
`ShanoirEventService.publishEvent`, which logs the whole event and publishes JSON to
`events-exchange` with routing key = event type (`ShanoirEventService.java:57-60`). Event types are
constants ending in `.event` (`ShanoirEventType.java:22+`). `shanoir-events-queue` binds `*.event`
with a **single** consumer (`RabbitMQUserService.java:67-72`, `singleConsumerFactory`).
`ShanoirEventsService.addEvent` persists it and, for 12 long-running task types, re-reads it and
pushes it to SSE subscribers (`events/ShanoirEventsService.java:57-78`).

There is a second, parallel channel: `logback-spring.xml:39-41` routes the
`org.shanoir.ng.shared.event` logger to a dedicated `/var/log/shanoir-ng-logs/shanoir-events.log`
file in every service. That is a plain `FileAppender` with **no rotation policy** — unbounded
growth on a shared docker volume (`docker-compose.yml:148`).

### 6.2 Is it a reliable audit trail? No.

**Mutability.** `ShanoirEventLight.id` is `@Id` with no `@GeneratedValue`
(`events/ShanoirEventLight.java:38-39`), commented "*normally generated BEFORE arriving here*", and
the producer sets it to `UUID.randomUUID().getMostSignificantBits() & Long.MAX_VALUE`
(`shared/event/ShanoirEvent.java:65`). `ShanoirEventsService.addEvent` calls `repository.save()`
(`:59`), and Spring Data's `save()` on a non-null id performs `em.merge()`, i.e. an **UPDATE if the
row exists**. This is intentional for progress updates on import tasks, but the consequence is that
the `events` table is mutable state, not an append-only log: any producer that can reach RabbitMQ
can replace the contents of an arbitrary existing audit row by reusing its id. There is no hash
chain, no signature, no `created_by_service` column, no immutability trigger.

**Silent loss.** `receiveEvent` wraps everything in
`throw new AmqpRejectAndDontRequeueException(...)` (`RabbitMQUserService.java:78-81`). With no DLQ
configured on `shanoir-events-queue` (`RabbitMQConfiguration.java:410`), the message is discarded.
A JSON schema mismatch, a constraint violation, or a users-DB outage therefore **destroys** the
audit record — and, because `addEvent` is inside the try block, a DB outage destroys *every* audit
event platform-wide for the duration.

**Loss at the producer too.** `ShanoirEventService.publishEvent` catches `JsonProcessingException`
and only logs (`:61-64`). Publishing is not confirmed (no publisher confirms / mandatory flag), so
a broker-side routing failure is invisible.

**Coverage gaps.** Only three actions in this service emit events:
`DELETE_USER_EVENT` (`UserServiceImpl.java:149`), `UPDATE_USER_EVENT` (`:365`),
`ACCESS_REQUEST_EVENT` / `USER_ADD_TO_STUDY_EVENT` (`AccessRequestApiController.java:118,243`).
Not audited: user **creation**, account-request approval/denial, extension approval/denial,
password reset, role change (only a generic "user updated" with an empty message), TOTP
enable/disable, account enable/disable, **and every mass e-mail sent** (§4.1). For a platform where
"who was granted access to what data, by whom, when" is the central compliance question, the gaps
are material. `UPDATE_USER_EVENT` in particular carries an empty message
(`UserServiceImpl.java:365`) — no before/after diff, so it cannot answer "who escalated this user
to admin".

**Retention.** `deletePeriodically()` hard-deletes everything older than 361 days
(`ShanoirEventsService.java:124-129`), a magic number, unconfigurable, with no archive. That is
shorter than the retention normally required for clinical-research audit trails, and it is
irreversible. The method is also `private` and calls a derived `deleteBy...` query
(`ShanoirEventRepository.java:47`) with **no `@Transactional`** — derived delete queries are not
transactional by default in Spring Data JPA, so I expect this job to fail at runtime with
`InvalidDataAccessApiUsageException: no transaction is in progress`. (Inference from the Spring Data
contract; not executed.)

**Queryability.** Only `GET /events/{studyId}` (`events/EventsApi.java:44`) — events are queryable
*by study only*. `studyId` is nullable on the entity (`ShanoirEventLight.java:70`) and is not set by
`UserServiceImpl`'s user events, so **user-lifecycle events are unreachable through the API
entirely**. There is no "all events for user X" or "all events of type Y" endpoint for an auditor,
and the one query that exists is vulnerable to JPQL injection (§9.3).

### 6.3 Throughput

One consumer thread × (1 INSERT/UPDATE + 1 SELECT) per event (`ShanoirEventsService.java:59-62`;
the SELECT exists only to read back the `@CreationTimestamp`). The SSE fan-out then walks the whole
`EMITTERS` list per matching event (`:136-160`). A bulk import producing progress events at high
rate will queue behind this single consumer.

---

## 7. Code quality assessment

**Swallowed exceptions and lost context**

- `EmailServiceImpl.java:139-140` — `catch (Exception e) { }`, completely empty.
- `UserServiceImpl.java:152-154` — `catch (Exception e) { LOG.error("Error while deleting user."); }`
  drops the exception object *and* the user id.
- `KeycloakClient.java:325-327` and `:355-357` — all Keycloak update/delete failures logged and
  swallowed; the caller believes the write succeeded.
- `EventsApiController.java:46-48,58-60` — `catch (Exception e)` and re-throw with
  `e.getMessage()` as the client-facing error body: internal exception text (JPQL fragments,
  constraint names) is returned to the caller.
- `ShanoirEventService.java:63` — `LOG.error("Thrown exception: {}", e)` passes the exception as a
  format argument rather than a throwable, so **no stack trace is logged**.

**Log hygiene / PII**

- Eight `LOG.info(content)` calls dump the full rendered HTML e-mail
  (`EmailServiceImpl.java:180,203,503,543,578,599,631,713`). `notifyStudyAdminDataImported`'s body
  contains subject name, examination id, dataset names and study name.
- `EmailServiceImpl.java:673` logs an invited e-mail address at **ERROR** level for a nominal
  operation.
- `EventsApiController.java:54` logs at INFO on an anonymous endpoint — trivially log-floodable.
- `RabbitMQUserService.java:74` logs every event payload at INFO.
- `ShanoirEventService.java:48-57` dumps `report` (which for imports contains per-series detail).

**Dead code**

- `PasswordUtils.getHash` (`utils/PasswordUtils.java:143-167`) — unsalted **SHA-1**, truncated to 14
  chars, and its body appends both hex and signed-decimal per byte (`:158-159`), which is simply
  wrong. Referenced only by its own test.
- `ExtensionWithMotivationValidator.isValid` returns `true` with the real logic commented out
  (`shared/validation/ExtensionWithMotivationValidator.java:36-42`), so the `@ExtensionWithMotivation`
  constraint on `User` (`user/model/User.java:54`) is a no-op.
- `UserApiControllerITTest.java` (198 lines) and `RoleApiControllerITTest.java` (105 lines) are
  100% commented out.
- 4 unreferenced templates (§4.4); `user/model/dto/UserDTO.java` and `user/model/UserContext.java`
  are unused on the live paths; `role/repository/RoleRepositoryCustom.getAllNames()` exists only to
  serve `KeycloakClient.java:342`.
- `AccessRequestServiceImpl.create()` and `createAllowed()` are byte-identical
  (`accessrequest/controller/AccessRequestServiceImpl.java:42-49`).
- `UserServiceImpl.findByEmail`/`findByEmailForExtension` and
  `findByUsername`/`findByUsernameForInvitation` are identical bodies that exist only to carry
  different `@PreAuthorize` annotations (`UserServiceImpl.java:207-243`). That is a legitimate
  trick, but it is undocumented and the weaker variant (`UserService.java:121`) is the source of
  §9.2.
- Unreachable branch: `AccessRequest.getMotivation()` is read at `UserServiceImpl.java:333` on an
  object created three lines earlier at `:321` whose motivation was never set — the ternary can
  never take its true branch.

**Duplication**

- `getUserRepresentation` is implemented twice with divergent behaviour:
  `KeycloakClient.java:367-384` strips non-letter characters from names and omits `emailVerified`;
  `ShanoirUsersManagement.java:223-239` does not strip and sets `emailVerified = true`.
- The eight private `notifyAdmin*`/`notifyUser*` methods in `EmailServiceImpl.java:322-463` are the
  same 15-line block with a different template name and subject.
- `UserPrivacySecurityService.filterPersonnalData` is invoked twice per request for `EXPERT`s —
  once from `UserService.java:77` and again from `UserApi.java:99`.

**Style / correctness smells**

- `UserPrivacySecurityService.filterPersonnalData` (`user/security/UserPrivacySecurityService.java:34-70`)
  **mutates** its argument and always returns `true`, while being used as a boolean authorization
  expression. It is safe today only because `spring.jpa.open-in-view: false`
  (`application.yml:39`) means the entities are detached; re-enabling OSIV would let those nulls be
  flushed to the database. Six blank lines at `:61-66`.
- `ShanoirEvent.toLightEvent()` (`events/ShanoirEvent.java:53-58`) casts `this` to its own
  superclass and mutates the receiver (`setReport(null)`) — the javadoc admits it. Same latent
  data-loss risk if OSIV is ever enabled.
- `AsyncTaskApiController.findTasks`'s comparator never returns 0
  (`tasks/AsyncTaskApiController.java:78`), violating the `Comparator` contract; `List.sort`'s
  TimSort can throw `IllegalArgumentException: Comparison method violates its general contract!`
  on lists longer than 32 with equal timestamps.
- `KeycloakClient.getKeycloak()` lazy init is not thread-safe (`:94-100`) and
  `resetPassword` bypasses it entirely, using the raw field (`:155`) — see §9.6.
- `URLEncoder.encode(String)` single-arg, deprecated, platform-default charset
  (`EmailServiceImpl.java:681,684,687`).
- `UserRepository.findAdminEmails()`'s javadoc documents a `roleName` parameter the method does not
  have (`user/repository/UserRepository.java:34-42`), and the JPQL selects the unqualified `email`.
- Checkstyle exists (`shanoir-ng-back/checkstyle.xml`) but is evidently not enforced.

---

## 8. Test coverage analysis

### 8.1 Numbers

22 test classes, 3,645 LOC, **155 `@Test` annotations of which 15 are inside fully commented-out
files** → **140 live tests**. Ratio 3,645 test LOC : 8,680 main LOC (0.42), the best of the three
large back-end services but heavily skewed.

| Style | Classes | Notes |
|---|---|---|
| `@SpringBootTest` | 4 | `UserServiceTest`, `UserServiceSecurityTest`, `EmailServiceTest` (GreenMail SMTP on :3025), `ScheduledTasksTest` |
| `@WebMvcTest` | 5 | `UserApiControllerTest`, `AccountRequestApiControllerTest`, `AccessRequestApiControllerTest`, `ExtensionRequestApiControllerTest`, `MassEmailApiControllerTest`, `RoleApiControllerTest` |
| `@DataJpaTest` | 2 | `UserRepositoryTest`, `RoleRepositoryTest` |
| Plain Mockito | 4 | `MassEmailServiceTest`, `KeycloakClientTest`, `AbstractUserRequestApiControllerTest`, plus JUnit-4-style below |
| Dead | 2 | `UserApiControllerITTest`, `RoleApiControllerITTest` |

`RoleServiceTest.java:41` and `PasswordUtilsTest.java:26` use JUnit 4's
`@RunWith(MockitoJUnitRunner.class)`. Unless `junit-vintage-engine` is on the classpath (it is not
declared in `shanoir-ng-users/pom.xml` and I did not find it in the parent), these **9 tests are
silently not executed** by the Jupiter engine.

### 8.2 Per-package coverage map

| Package | Live tests | Verdict |
|---|---|---|
| `user/service` | ~33 (`UserServiceTest` 19, `UserServiceSecurityTest` 4 dense methods) | good behavioural + authorization coverage |
| `email` (`EmailServiceImpl`, `MassEmail*`) | 39 | good; GreenMail asserts real message content |
| `accessrequest` | 15 (controller only) | **no authorization test at all** |
| `user/controller` | 7 | thin; `@PreAuthorize` not enforced in the slice (§8.3) |
| `user/utils` (`KeycloakClient`, 385 LOC) | 3 | **only `getUsersEnabledStatus` is tested.** Create/update/delete/TOTP/resetPassword: 0 |
| `scheduling` | 3 | reasonable |
| `role/*` | 4 live (+2 dead) | trivial |
| `shared/*` | 23 (`AbstractUserRequestApiControllerTest`, username generation) | good |
| `utils/PasswordUtils` | 8 (likely not run) | tests a dead method |
| **`events/*` (862 LOC)** | **0** | **zero coverage** |
| **`tasks/*` (209 LOC)** | **0** | **zero coverage** |
| **`configuration/amqp/*` (243 LOC)** | **0** | **zero coverage** |
| **`messaging/*`** | **0** | zero |
| **`ShanoirUsersManagement` (282 LOC)** | **0** | zero |
| **`accountrequest` controller** | 3 | `AccountRequestApiSecurityTest` has exactly **1** test |
| **`extensionrequest`** | 4 | happy path + two rejections; no Keycloak-failure path |

**Roughly 1,600 main LOC — the entire audit-log subsystem, all AMQP listeners, the SSE task API and
the Keycloak migration runner — have no test whatsoever.**

### 8.3 Quality critique

- **`@PreAuthorize` is not enforced in 5 of the 6 `@WebMvcTest` slices.** All six use
  `@AutoConfigureMockMvc(addFilters = false)`, and the production `SecurityConfiguration` (which
  carries `@EnableMethodSecurity`) is not part of the MVC slice. Only `MassEmailApiControllerTest`
  fixes this, with an explicit `@Import` of a local `@EnableMethodSecurity` configuration and a
  clear comment (`email/MassEmailApiControllerTest.java:51-64`). Everywhere else the `@WithMockUser`
  annotations are decorative: `UserApiControllerTest.findUsersTest` with `ROLE_EXPERT`
  (`:137-141`) would pass identically with no role at all. **The controller-level authorization
  matrix of the most sensitive API in the platform is untested.**
- `UserServiceSecurityTest` is the best test in the module — a real role × operation matrix over
  the live Spring context (`user/UserServiceSecurityTest.java:117-238`). It also *documents* two of
  the findings in this report: it asserts that an anonymous caller may call `requestExtension`
  (`:130`) and `updateLastLogin` (`:148`).
- `EmailServiceTest` asserts on actual received SMTP message content via GreenMail — genuinely good
  (`email/EmailServiceTest.java:83-125`).
- `KeycloakClientTest` mocks the whole Keycloak admin client by subclassing and overriding
  `getKeycloak()` (`user/utils/KeycloakClientTest.java:63-68`) — pragmatic, but the pattern is only
  applied to one method.
- `AccessRequestApiControllerTest` is assertion-rich for the happy paths (verifies AMQP sends and
  e-mail calls, `:130-141`) but never once exercises "wrong user calls this endpoint".
- `TestConfiguration.java` mocks `RabbitTemplate` globally for every `@SpringBootTest`, which means
  **no test ever exercises a real message round-trip or a listener**.
- 30+ lines of commented-out `given(...)` stubs left in `UserServiceSecurityTest.java:102-113`.

### 8.4 Highest-value missing tests

1. **Controller authorization matrix for `AccessRequestApi`** — `ROLE_USER` calling
   `resolve/{id}`, `byStudy/{id}`, `{id}`, `invitation/` must be 403. This test would fail today
   and is the direct regression guard for findings §9.1 and §9.2.
2. **`UserApi` authorization matrix with method security actually enabled** — copy the
   `@Import(@EnableMethodSecurity)` trick from `MassEmailApiControllerTest`. Include the admin
   path/body-mismatch case for §9.8.
3. **Keycloak failure paths**: `create()` when `createUserWithPassword` throws — assert no orphan
   DB row (this will fail; it documents the required fix). `deleteById()` when Keycloak delete
   throws. `update()` when the realm-role swap throws.
4. **`RabbitMQUserService.receiveEvent`**: malformed JSON, duplicate id (assert the upsert
   behaviour is or is not intended), and DB-down behaviour.
5. **`ShanoirEventRepositoryImpl.find`** with a hostile `searchField` and a hostile `sort`
   parameter.
6. **`ScheduledTasks.checkExpirationDate`** when `emailService` throws for user *k* of *n* —
   assert the remaining users are still processed (they are; worth locking in) and that
   `updateExpirationNotification` was not committed for the failed user (it was — see §9.11).
7. **`ShanoirEventsService.deletePeriodically`** — a `@DataJpaTest` that would immediately expose
   the missing `@Transactional`.
8. `MassEmailServiceImpl.resolveRecipients` when Keycloak is unreachable, and the
   `TaskRejectedException` path when >10 campaigns are queued.

---

## 9. Bugs & correctness risks

| # | Severity | Title | Location |
|---|---|---|---|
| 9.1 | Critical | Any authenticated user can approve/refuse any study access request | `accessrequest/controller/AccessRequestApi.java:73`; `AccessRequestApiController.java:170-211` |
| 9.2 | Critical | Any authenticated user can dump any user's PII by username | `AccessRequestApiController.java:238-261`; `user/service/UserService.java:121` |
| 9.3 | High | JPQL injection via `searchField` and `sort` on the audit-log query | `events/ShanoirEventRepositoryImpl.java:72-74,98-100` |
| 9.4 | High | Audit rows are upsertable / overwritable by producers | `events/ShanoirEventLight.java:38-39`; `events/ShanoirEventsService.java:59` |
| 9.5 | High | Audit events permanently dropped on any failure; no DLQ platform-wide | `configuration/amqp/RabbitMQUserService.java:78-81`; `RabbitMQConfiguration.java:41-60` |
| 9.6 | High | `KeycloakClient.resetPassword` NPEs when it is the first Keycloak call after startup | `user/utils/KeycloakClient.java:155` |
| 9.7 | High | Keycloak migration uses fuzzy `search()`, silently skipping users | `ShanoirUsersManagement.java:191` |
| 9.8 | Medium | SpEL precedence defeats `idMatches` for admins on `PUT /users/{id}` | `user/controller/UserApi.java:153` |
| 9.9 | Medium | NPE on `isAccountRequestDemand()` unboxing in the refuse branch | `AccessRequestApiController.java:205` |
| 9.10 | Medium | NPE in field-edition validation when the posted `id` does not exist (anonymous DoS + id oracle) | `FieldEditionSecurityManagerImpl.java:53,62`; `AccountRequestApiController.java:54` |
| 9.11 | Medium | Expiry cron marks the notification sent before the e-mail is sent | `scheduling/ScheduledTasks.java:63-69` |
| 9.12 | Medium | `deletePeriodically` derived-delete without `@Transactional` | `events/ShanoirEventsService.java:124-129` |
| 9.13 | Medium | `users` container is missing 4 mandatory SMTP env vars | `application.yml:75-79` vs `docker-compose.yml:127-146` |
| 9.14 | Medium | `ms_users_to_ms_studies_user_delete` has no consumer; user deletes double-published | `messaging/InterMicroservicesCommunicator.java:49` |
| 9.15 | Medium | RPC listeners return `null` on empty result → 5 s blocking timeout on the HTTP thread | `RabbitMqStudyUserService.java:76,88`; `EmailServiceImpl.java:647` |
| 9.16 | Medium | NPE in mail preparators when the acting user was deleted | `EmailServiceImpl.java:468/494`, `515/535`, `170/765` |
| 9.17 | Low | Comparator contract violation can throw on `/tasks` | `tasks/AsyncTaskApiController.java:78` |
| 9.18 | Low | `@PostAuthorize` NPE when `findUsers()` returns 204 | `user/controller/UserApi.java:99` + `UserApiController.java:108-110` |
| 9.19 | Low | `getByid` calls `Optional.get()` unguarded → 500 instead of 404 | `AccessRequestApiController.java:214` |
| 9.20 | Low | Keycloak silently mangles names; `@Unique` check is TOCTOU | `KeycloakClient.java:379-380`; `UniqueConstraintManagerImpl.java:64-66` |

### 9.1 (Critical) `AccessRequestApi` has no authorization at all

`accessrequest/controller/AccessRequestApi.java` does not import or use `@PreAuthorize` on any of
its six endpoints. The only gate is `anyRequest().authenticated()`
(`SecurityConfiguration.java:79-80`). The service layer does not compensate: the whole
`accessrequest` package contains exactly one `@PreAuthorize`, and it is on `deleteById`
(`AccessRequestService.java:38`), which no REST endpoint reaches. The author of that annotation
clearly knew the mechanism — it was simply not applied to the reachable methods.

The worst consequence is `PUT /accessrequest/resolve/{accessRequestId}` with body `true`
(`AccessRequestApiController.java:170`). The handler:
1. loads the request by id — no ownership or study-rights check (`:174`);
2. sets `status = APPROVED` and persists (`:179,184`);
3. sends a `USER_ADD_TO_STUDY_EVENT` to `study-subscription-queue` (`:201`), which the studies
   service consumes at `shanoir-ng-studies/.../RabbitMQStudiesService.java:233` and turns into a
   real study membership.

**Any holder of a `ROLE_USER` token can therefore grant any pending requester access to any study's
imaging data.** The service-layer `@PreAuthorize` net does not help: this path never calls
`UserService`. Enumeration is trivial via `GET /accessrequest/byStudy/{studyId}` — also unguarded —
which returns every pending request (including each requester's full `User` object) for an
arbitrary study id.

The `validation = false` branch is worse in a different way: it calls
`userService.denyAccountRequest` (`:206`), which **deletes the user from the DB and from Keycloak**
(`UserServiceImpl.java:169-180`). That call *is* guarded, but at `hasAnyRole('ADMIN','EXPERT')`
(`UserService.java:68`) — so **any EXPERT, not just a study administrator, can delete any user who
has a pending account request**. And because the status update at `:184` already committed, a
rejected call still leaves the access request permanently marked APPROVED/REFUSED.

*Fix:* add `@PreAuthorize` to all six methods. `resolve` and `byStudy` need
`hasRole('ADMIN') or @shanoirUsersManagement.hasRightOnStudy(#studyId, 'CAN_ADMINISTRATE')` — for
`resolve` the study id must be resolved from the access request before the check, so use a
dedicated `@Service` security bean rather than an inline SpEL. `getByid` needs an owner-or-study-admin
check. Wrap the handler in `@Transactional`.

### 9.2 (Critical) User enumeration and PII dump via the invitation endpoint

`PUT /accessrequest/invitation/?studyId=1&studyName=x&email=<login>`
(`AccessRequestApiController.java:218-279`). If the value contains no `@`, it is treated as a
username and looked up via `userService.findByUsernameForInvitation`, whose `@PreAuthorize` is
`hasRole('ADMIN') or (hasAnyRole('USER','EXPERT'))` (`user/service/UserService.java:121`) — i.e.
every authenticated user. On a hit the handler returns an `AccessRequest` whose `user` field is the
**full `User` entity** (`:256,261`), serialized with `email`, `firstName`, `lastName`, `role`,
`creationDate`, `lastLogin`, `expirationDate`. The `@PostAuthorize` privacy filter that protects
`GET /users` (`UserApi.java:99`) is not applied here.

So a plain `ROLE_USER` can walk a username dictionary and harvest the full staff directory,
including e-mail addresses and who the administrators are. Each hit also writes a spurious
`USER_ADD_TO_STUDY_EVENT` into the audit log (`:243-250`), polluting it.

For `EXPERT`/`ADMIN` the `@` branch additionally sends an invitation e-mail to an **arbitrary
external address** with attacker-controlled `studyName`, `issuer` and `function` embedded in the
body and in the signup URL (`EmailServiceImpl.java:656-694`) — a phishing relay from the
institution's own SMTP server.

*Fix:* return a minimal DTO (`{found: true, userId, username}`), require study
`CAN_ADMINISTRATE` on `#studyId`, and rate-limit.

### 9.3 (High) JPQL injection in the audit-log search

```java
} else {
    queryEndStr += "e." + searchField + " LIKE CONCAT('%', ?" + searchStrIndex + ", '%') ";
}
```
`events/ShanoirEventRepositoryImpl.java:74` (and `:72` for the `creationDate` branch). `searchField`
arrives straight from the request (`EventsApiController.java:36` → `EventsApi.java:46`) and the
`if/else if` chain at `:63-72` whitelists only five values; anything else falls into the
concatenating `else`. Sorting is equally exposed: `queryStr += "e." + order.getProperty()`
(`:100`), where `order` comes from the client-controlled `Pageable` `sort` parameter.

This is HQL/JPQL, not native SQL, so it is not a direct route to arbitrary SQL — but HQL supports
subqueries and cross-entity navigation, which is enough to exfiltrate from other mapped entities
(e.g. `User`) or to force parse errors that leak schema through
`EventsApiController.java:47`'s `e.getMessage()` echo. The endpoint requires study
`CAN_ADMINISTRATE`, which limits the attacker set but does not make it acceptable.

*Fix:* replace both concatenations with an explicit allow-list `enum` → property mapping, and
reject unknown values with 422.

### 9.4 (High) The audit log is upsertable

See §6.2. Concretely: `ShanoirEventLight.java:38-39` has `@Id` with no generation strategy;
`ShanoirEvent` instances arrive over AMQP with a producer-chosen id
(`shared/event/ShanoirEvent.java:65`) that is fully settable from JSON (`setId`, `:99`);
`ShanoirEventsService.addEvent` calls `repository.save()` (`:59`) which merges.

*Fix:* separate the "task progress" concern from the "audit record" concern. Progress belongs in a
mutable `tasks` table keyed by a producer-supplied correlation id; audit records belong in an
append-only table with a DB-generated id, an `INSERT`-only repository method, a
`source_service` column, and ideally a per-row HMAC or a hash chain over
`(prev_hash, id, type, user, object, timestamp)`.

### 9.5 (High) Audit events are dropped, not dead-lettered

`RabbitMQUserService.java:78-81` converts every failure into
`AmqpRejectAndDontRequeueException`. `RabbitMQConfiguration.java:410` declares
`new Queue(SHANOIR_EVENTS_QUEUE, true)` with no arguments — no `x-dead-letter-exchange` — and
neither `multipleConsumersFactory` nor `singleConsumerFactory` (`:41-60`) configures a retry advice
chain. So a rejected message is gone.

The blast radius is the whole platform: `addEvent` (the DB write) is inside the `try`, so any
users-DB unavailability discards every audit event from every service for the duration of the
outage, with only a log line to show for it.

The converse problem applies to the six mail listeners: they also throw
`AmqpRejectAndDontRequeueException`, so a transient SMTP outage permanently loses the notification.
And any listener that throws a *different* exception (e.g. the NPEs in §9.16, which are raised
inside `MimeMessagePreparator` and surface as `MailPreparationException`) is requeued forever by
the default `defaultRequeueRejected = true` — an infinite redelivery hot loop.

*Fix:* declare a DLX + `*-dlq` per queue; add a bounded `RetryTemplate` (3 attempts, exponential)
to both container factories; add an operational alert on DLQ depth.

### 9.6 (High) `resetPassword` NPEs on a cold service

```java
final UserResource userResource = keycloak.realm(keycloakRealm).users().get(keycloakId);
```
`user/utils/KeycloakClient.java:155` uses the raw `keycloak` field. Every other method in the class
goes through `getKeycloak()` (`:94-100`), which lazily instantiates it. The field is `null` until
some other method runs first.

The only caller is `ExtensionRequestApiController.java:59`, reached from the **anonymous**
`POST /extensionrequest`. On a freshly restarted container with no prior user create/update/delete,
the first extension request throws `NullPointerException` → 500, and — because
`userService.requestExtension` already ran at `:58` — the user is left flagged
`extensionRequestDemand = true` with the admin already notified, but with no new password.
Retrying then hits the `"An extension has already been requested"` guard at `:53` and returns 406.
**The user is stuck** until an admin intervenes.

*Fix:* one-character change to `getKeycloak()`; also make `getKeycloak()` thread-safe (or just
build the client in `@PostConstruct`).

### 9.7 (High) Keycloak migration uses a fuzzy search

`ShanoirUsersManagement.java:191`:
```java
final List<UserRepresentation> userRepresentationList =
        keycloak.realm(keycloakRealm).users().search(user.getUsername());
```
Keycloak's `search(String)` is an **infix, multi-field** search (username, first name, last name,
e-mail). If any realm user matches `jdoe` as a substring — `jdoe2`, or someone whose last name is
"Jdoe" — the list is non-empty and the branch at `:192-193` logs "already existing, do nothing" and
**skips creating the real account**. That user then has a DB row with `keycloak_id = NULL` and can
never log in, silently.

The correct call is used 60 lines away for the VIP service account:
`users().searchByUsername(this.vipSrvUsername, true)` (`:250`). Use that, and also verify the
returned representation's username equals the requested one.

### 9.8 (Medium) SpEL precedence defeats the id-match guard for admins

`user/controller/UserApi.java:153`:
```java
@PreAuthorize("hasRole('ADMIN') or (hasAnyRole('USER', 'EXPERT') and @isMeSecurityService.isMe(#userId)) and @controllerSecurityService.idMatches(#userId, #user)")
```
`and` binds tighter than `or`, so this parses as
`ADMIN or ((USER|EXPERT and isMe) and idMatches)`. For an administrator, `idMatches` is never
evaluated, so `PUT /users/5` with a body containing `"id": 9` updates user **9**. The controller
never looks at `userId` either (`UserApiController.java:184-191` uses `user.getId()` only, and
`UserServiceImpl.update` looks up `user.getId()` at `:361`).

Impact: no privilege escalation (the caller is already an admin), but reverse-proxy access logs,
any URL-based monitoring, and the operator's mental model all record the wrong subject — an
audit-integrity defect on the most sensitive write in the service. The identical construction is
written **correctly** with explicit grouping for the same three predicates at
`email/MassEmailApi.java:66-67`, so this is an oversight rather than a convention.

*Fix:* `(hasRole('ADMIN') or (hasAnyRole('USER','EXPERT') and @isMeSecurityService.isMe(#userId))) and @controllerSecurityService.idMatches(#userId, #user)`.
The same audit applies to every multi-clause `@PreAuthorize` in the codebase.

### 9.9 (Medium) NPE unboxing `isAccountRequestDemand()`

`AccessRequestApiController.java:205`: `if (resolvedRequest.getUser().isAccountRequestDemand())`.
The getter returns `Boolean` (`user/model/User.java:154`) and the column is nullable (no `@NotNull`
on the field, `:62-63`). The sibling branch 17 lines earlier guards correctly:
`isAccountRequestDemand() != null && isAccountRequestDemand()` (`:188`). Refusing an access request
from a user with a `NULL` flag throws NPE → 500, **after** the status was already persisted at
`:184` and after the refusal e-mail was already sent at `:203`.

### 9.10 (Medium) Anonymous NPE / user-id oracle in field-edition validation

`FieldEditionSecurityManagerImpl.validate` (`shanoir-ng-ms-common/.../security/FieldEditionSecurityManagerImpl.java:50-56`)
does `repository.findById(entity.getId()).orElse(null)` and passes the result to `validateUpdate`,
which immediately calls `originalEntity.getClass()` (`:62`) — NPE when the id does not exist.

`POST /accountrequest` is anonymous and calls `validate(user, result)`
(`accountrequest/controller/AccountRequestApiController.java:54`) with a body that is free to
contain `"id": N` (`AbstractEntity.setId` is public and un-ignored). So an unauthenticated caller
gets a 500 for a non-existent id and a 422 for an existing one — a clean **user-id enumeration
oracle**, plus an unauthenticated 500 generator.

The subsequent mass-assignment (overwriting user *N* via `userRepository.save()`'s merge semantics,
which `UniqueConstraintManagerImpl.java:66` would happily allow because it exempts the same id) is
**blocked**, but only by the service-layer SpEL guard
`@PreAuthorize("#user.getId() == null && ...")` at `user/service/UserService.java:178`. That single
expression is the only thing standing between an anonymous request and arbitrary user-row
overwrite. It deserves an explicit test (there is none) and a belt-and-braces
`user.setId(null)` in the controller.

*Fix:* null-check `originalEntity` and return a not-found error; null the id in the controller;
add the regression test.

### 9.11 (Medium) Expiry notification marked sent before it is sent

`scheduling/ScheduledTasks.java:63-69`:
```java
userToNotify.setFirstExpirationNotificationSent(true);
try {
    userService.updateExpirationNotification(userToNotify, true);   // commits
    emailService.notifyAccountWillExpire(userToNotify);             // may throw
} catch (Exception e) { LOG.error(...); }
```
`updateExpirationNotification` commits its own transaction (`UserServiceImpl.java:397-404`) before
the mail is attempted. An SMTP failure is caught and logged, and because the flag is now `true` the
user is excluded from `findByExpirationDateLessThanAndFirstExpirationNotificationSentFalse`
(`user/repository/UserRepository.java:60`) forever. **The user is never warned that their account
is about to expire.** Lines 75-81 have the identical bug for the second notification.

There is also no locking: two `users` replicas would both run the 08:00 cron and double-send.

*Fix:* send first, then mark; or mark inside the same transaction as an outbox row.

### 9.12 (Medium) Retention job has no transaction

`events/ShanoirEventsService.java:124-129` calls `repository.deleteByLastUpdateBefore(...)`, a
Spring Data *derived delete* declared at `ShanoirEventRepository.java:47`. Derived
`deleteBy…`/`removeBy…` queries are not wrapped in a transaction by Spring Data (only the
`CrudRepository` built-ins are), so I expect this to throw at every execution. If so, **events are
never purged** and the table grows without bound; if the environment somehow supplies a transaction,
the opposite risk applies (a hard, unrecoverable purge with no archive). Either way it is
untested (`events/` has zero tests) and needs both `@Transactional` and a `@Modifying` bulk query
with a batch limit — deleting a year of platform-wide events in one statement will lock the table.

### 9.13 (Medium) `users` container is missing mandatory SMTP variables

`application.yml:75-79` dereferences `${SHANOIR_SMTP_FROM}`, `${SHANOIR_SMTP_AUTH}`,
`${SHANOIR_SMTP_STARTTLS_ENABLE}` and `${SHANOIR_SMTP_STARTTLS_REQUIRED}` **with no defaults**
(unlike `SHANOIR_SMTP_USERNAME`/`PASSWORD`, which have `:` defaults on `:72-73`). But the `users`
service block forwards only `SHANOIR_SMTP_HOST` and `SHANOIR_SMTP_PORT` in **both**
`docker-compose.yml:145-146` and `docker-compose-dev.yml:157-158`, and
`docker-compose/users/entrypoint:18` `require`s only `SHANOIR_SMTP_HOST`. The full set *is*
forwarded — but to the **keycloak** service (`docker-compose.yml:53-60`). Compose only injects
variables that are listed under a service, so the `.env` definitions at `.env:24-29` do not reach
the users container.

Expected symptom: `IllegalArgumentException: Could not resolve placeholder 'SHANOIR_SMTP_FROM'` at
startup. I could not run the stack to confirm, so treat this as high-confidence-but-unverified;
either way the entrypoint's `require`/`optional` contract does not match `application.yml`.

Separately, `docker-compose.yml:129` pins `users:NG_v2.12.0` while the poms are at `3.4.0`.

### 9.14 (Medium) A user-delete message with no consumer, and a double publish

`messaging/InterMicroservicesCommunicator.java:49` publishes the deleted user id to
`ms_users_to_ms_studies_user_delete`. A repo-wide search finds the constant only in its declaration
(`RabbitMQConfiguration.java:166`), its queue bean (`:405`) and this publisher — **no
`@RabbitListener` consumes it**, so the queue accumulates messages until the broker's limits bite.

Meanwhile `UserServiceImpl.deleteById` *also* publishes a `ShanoirEvent` to `delete-user-queue`
(`:151`), which `shanoir-ng-studies/.../StudyUserServiceImpl.java:105` does consume. So there are
two parallel user-delete notification mechanisms, one of which is dead. Delete one.

### 9.15 (Medium) Empty AMQP RPC results block the request thread for 5 s

`RabbitMqStudyUserService.getStudyAdmins` and `getStudiesICanAdmin` return **`null`** when the
result set is empty (`shanoir-ng-study-rights/.../RabbitMqStudyUserService.java:76,88`). A `null`
return from a Spring AMQP RPC listener means no reply message is sent, so the caller's
`convertSendAndReceive` blocks until the default 5-second reply timeout and then returns `null`.

Callers: `EmailServiceImpl.findStudyAdmin` (`:647`) — so creating an access request against a study
that has no confirmed administrator adds 5 s of latency to `POST /accessrequest` and then silently
sends no notification (`:648-650`); and `AccessRequestApiController.findAllByAdminId` (`:153`) —
5 s on every page load for a user who administrates nothing.

*Fix:* return an empty list instead of `null` (in `study-rights`), and set an explicit short
`replyTimeout` on the `RabbitTemplate`.

### 9.16 (Medium) NPEs in mail preparators when the acting user no longer exists

`EmailServiceImpl.java:468` does `userRepository.findById(...).orElse(null)` and then dereferences
`u.getUsername()` at `:494` inside the lambda. Same at `:515`/`:535`. Same at `:170`/`:765`
(`buildStudyEmailVariables(user, …)` dereferences `user.getFirstName()`). The sibling method 40
lines below explicitly handles the null case with the comment *"We may come from challenge, the
user then does not exists"* (`:554-555,567,573`), so the null case is known to occur. The NPE is
thrown inside `MimeMessagePreparator`, surfacing as `MailPreparationException` from
`mailSender.send`, which for the AMQP-driven paths triggers the infinite-requeue behaviour of §9.5.

### 9.17 (Low) Comparator contract violation on `/tasks`

`tasks/AsyncTaskApiController.java:75-81` returns `1` or `-1` and never `0`, so for two events with
identical `lastUpdate` both `compare(a,b)` and `compare(b,a)` return `-1`. TimSort detects this on
lists longer than 32 elements and throws `IllegalArgumentException`. Replace with
`Comparator.comparing(ShanoirEventLight::getLastUpdate).reversed()`. `:72` also dereferences
`getLastUpdate()` without a null check.

### 9.18 (Low) `@PostAuthorize` NPE on an empty user list

`UserApiController.findUsers` returns `new ResponseEntity<>(HttpStatus.NO_CONTENT)` with a **null
body** (`:108-110`), and `UserApi.java:99`'s `@PostAuthorize` then calls
`filterPersonnalData(returnObject.getBody())`, whose first statement is `for (User user : users)`
(`user/security/UserPrivacySecurityService.java:38`). 500 instead of 204 for an EXPERT when the
list is empty. Same shape at `UserApi.java:118`.

### 9.19 (Low) Unguarded `Optional.get()`

`AccessRequestApiController.java:214`: `accessRequestService.findById(accessRequestId).get()` →
`NoSuchElementException` → 500 for a missing id. Every sibling method uses `.orElse(null)`.

### 9.20 (Low) Silent name mangling and a TOCTOU unique check

`KeycloakClient.java:379-380` strips every character outside `\p{L}\p{M}\s'-` from the first and
last name before writing to Keycloak, without telling anyone. The DB keeps the original, so
`users.first_name` and the Keycloak profile diverge for anyone with e.g. a name containing a
period. `ShanoirUsersManagement.getUserRepresentation` (`:235-236`) does **not** strip, so the two
write paths produce different Keycloak profiles for the same user. Both also NPE if
`getFirstName()`/`getLastName()` is null (`lastName` is only `@NotNull`, not `@NotBlank`).

`UniqueConstraintManagerImpl.java:64-66` checks uniqueness with a `SELECT` outside any transaction
covering the later `INSERT`; concurrent signups with the same e-mail race. The DB `unique`
constraints (`user/model/User.java:94,137`) are the real backstop, but the resulting
`DataIntegrityViolationException` becomes a 500, not a 422. Likewise the username-generation loop
(`shared/controller/AbstractUserRequestApiController.java:100-104`) probes `findByUsername` in a
loop — an unbounded, racy, N-query operation on a public endpoint.

---

## 10. Security & data-protection review

**Authentication.** Stateless JWT resource server against Keycloak
(`SecurityConfiguration.java:82-89`), CSRF disabled (correct for a bearer-token API), sessions
`STATELESS`. `realm_access` is dereferenced without a null check (`:83-84`) → NPE/500 for a token
lacking the claim.

**Authorization.** Two layers where they exist (controller interface + service interface) — a good
pattern. But coverage is uneven, and the gaps are exactly where the newest features live:
`AccessRequestApi` (0 annotations, §9.1/§9.2), `EventsApi.countPassedEvents` (0), `RoleApi` (0),
`AsyncTaskApi.updateTasks` (0), `UserApi.countActiveUsers` (0). The SpEL precedence bug (§9.8) shows
the expressions are not reviewed as code. **No `@WebMvcTest` except the mass-mail one actually
enforces `@PreAuthorize`** (§8.3), so none of this is caught by CI.

**Privilege escalation.** The direct path is closed: `role` and `expirationDate` carry
`@EditableOnlyBy(ROLE_ADMIN)` (`user/model/User.java:99,129`), enforced reflectively before every
update (`AbstractUserRequestApiController.java:111`). Note this relies on
`Utils.equalsIgnoreNull`'s `AbstractEntity` id-comparison special case
(`shanoir-ng-ms-common/.../Utils.java:78-80`); without it every self-update would be rejected as a
role change. The indirect paths are §9.1 (grant yourself study data access) and §9.2 (map the
admins).

**Anonymous endpoints.** Five, and three of them are write operations:
- `POST /accountrequest` — unauthenticated creation of a DB user **and** a Keycloak user, with two
  e-mails sent per call and no CAPTCHA, no rate limit, no e-mail verification. A spam bot can fill
  the users table, the Keycloak realm and the administrators' inboxes.
- `POST /extensionrequest` — unauthenticated **password reset**. Given a target's e-mail address,
  if that account is expired or has had its first expiry warning
  (`ExtensionRequestApiController.java:50`), an attacker forces a Keycloak password reset
  (`:59`) and the victim's current password stops working. Distinct responses (200 / 400 / 406)
  make it an account-state oracle.
- `POST /last_login_date` — unauthenticated write of `last_login` for an arbitrary username, and a
  204-vs-500 existence oracle (`user/controller/LastLoginDateApiController.java:38-49`). This is
  presumably called by a Keycloak login flow, but nothing binds it to that caller. It lets anyone
  forge the "last seen" column that an auditor would read.
- `GET /users/count` and `GET /events/count?days=N` disclose platform size and activity to the
  internet.

**Credentials & secrets.**
- `spring.datasource.username: users` / `password: password` **hard-coded in the production
  profile** (`application.yml:28-29`). Committed to a public repository.
- The Keycloak client uses the realm-`master` admin account (`application.yml:102-103` +
  `SHANOIR_KEYCLOAK_USER`/`PASSWORD`). A compromise of this service is a compromise of the entire
  Keycloak installation. It should be a dedicated service account in the `shanoir-ng` realm with
  only `manage-users` + `view-realm`.
- Generated passwords are e-mailed in **cleartext** (`notifyCreateUser.html:25`,
  `notifyCreateAccountRequest.html:28`, `notifyUserResetPassword.html:21,29`). They are marked
  temporary in Keycloak (`KeycloakClient.java:122,152`), which mitigates but does not remove the
  exposure — mail is stored indefinitely in mailboxes. Keycloak's built-in
  `execute-actions-email` (UPDATE_PASSWORD) would replace this with a single-use, expiring link.
  Passwords are 12 chars from a 66-character alphabet using `SecureRandom`
  (`utils/PasswordUtils.java:105-131`) — adequate.
- `PasswordUtils.getHash`'s unsalted SHA-1 (`:143-167`) is dead but will be flagged by any scanner;
  delete it.

**AMQP (platform-wide).** `docker-compose/users/entrypoint:39` (and the identical line in
`studies`, `datasets`, `import`, `preclinical`) exports
`SPRING_AMQP_DESERIALIZATION_TRUST_ALL=true`. No `MessageConverter` bean is defined anywhere in the
repository, so Spring AMQP's default `SimpleMessageConverter` is in force and non-String payloads
travel as **Java serialization** (e.g. `convertSendAndReceive(STUDY_ADMINS_QUEUE, studyId)` at
`EmailServiceImpl.java:647` and its `(List<Long>)` reply cast at `:647`). Trust-all disables the
allowed-class patterns, so anyone who can publish to a consumed queue can drive
`ObjectInputStream` with arbitrary classes on the classpath — a classic deserialization-RCE
posture. There is no evidence of RabbitMQ authentication hardening in `application.yml:64-66` (no
username/password configured at all, i.e. `guest/guest`). **This is the single most important
cross-service item in this report.**

**PII / PHI.** §7 lists eight full-e-mail-body log statements plus the event dump. The `logs`
docker volume is shared across all services (`docker-compose.yml:148`) and
`shanoir-events.log` never rotates. `notifyStudyAdminDataImported` bodies contain subject names and
examination identifiers — for a pseudonymised platform, that is exactly the linkage data that must
not sit in plaintext operational logs.

**E-mail security.** Header injection is largely handled by JavaMail's own encoding in
`MimeMessageHelper.setSubject/setTo`, but subjects are built by string concatenation from
cross-service data (`EmailServiceImpl.java:490,531,569,593,622,662,707,731`) and recipient lists
come from an AMQP payload (`:471,518,561`) — a compromised or buggy producer chooses who gets
mailed. Body injection is correctly handled for mass mail (`HtmlUtils.htmlEscape` at `:801`, the
only `th:utext` at `templates/massEmail.html:21`); every other template uses `th:text`. The
contract "the caller escapes, the template does not" is stated only in an HTML comment
(`massEmail.html:20`) and is one careless edit away from an HTML-injection bug. `setFromUser`
correctly puts the user address in `Reply-To` rather than `From` (`:141-146`).

**GDPR.**
- *Right to erasure*: `deleteById` removes the DB row and (best-effort) the Keycloak user, but the
  `events` table keeps `userId` and free-text `message` fields naming the person
  (`AccessRequestApiController.java:122`: `"New access request from " + user.getUsername()`) for up
  to 361 days, with no anonymisation step. Sent e-mails and logs are never touched.
- *Data minimisation*: `GET /users` returns every user with no pagination
  (`UserApiController.java:106-112`); `MassEmailServiceImpl.resolveRecipients` loads the entire
  users table into memory (`:65`).
- *Consent / lawful basis*: no consent record for e-mail communications; mass mail has no
  unsubscribe mechanism (`templates/massEmail.html`) and no audit record.
- *Purpose limitation*: the privacy filter (`UserPrivacySecurityService`) applies to exactly two
  endpoints; §9.2 bypasses it entirely.

---

## 11. Performance & scalability

**Mail on the request thread.** Every account workflow blocks on SMTP (§4.4), several on two
sequential sends. With `spring.threads.virtual.enabled: true` (`application.yml:56-57`) the thread
cost is low, but JavaMail's `Transport` and the JDBC driver use `synchronized`, which **pins**
virtual threads on Java 21 — so the carrier pool can still be starved by a slow SMTP relay. All
notification sends should go through the existing `@Async` infrastructure or, better, an outbox.

**Blocking AMQP RPC on the request thread.** Six call sites use `convertSendAndReceive`
(§4.2). Two of them hit the `null`-reply 5-second timeout on the empty-result path (§9.15). None
sets an explicit `replyTimeout`. `POST /accountrequest`, an anonymous endpoint, does a synchronous
RPC to the studies service (`UserServiceImpl.java:325`) *and* two SMTP sends *and* a Keycloak
round-trip before responding.

**Keycloak calls on the read path.** `UserServiceImpl.findById` issues **two extra Keycloak HTTP
calls per user read** for administrators (`:222,227`). The admin user-list page therefore costs
2 × N Keycloak calls if it drills down. `getUsersEnabledStatus` (`KeycloakClient.java:279-296`)
shows the team knows how to batch this; `findById` should use a short-TTL cache or the batch call.

**Unbounded queries.** `findAll()` on users (`UserServiceImpl.java:193`, `MassEmailServiceImpl.java:65`),
`studyUserRightsRepository.findAll()` for admins (`AccessRequestApiController.java:150`),
`accessRequestService.findByStudyIdAndStatus` with no limit (`:284`). None paginated. `User` has an
eager `@ManyToOne Role` and an eager `@OneToOne AccountRequestInfo`
(`user/model/User.java:66,127`), so `findAll()` is a classic **N+1** (one secondary select per user
for the one-to-one, unless batch fetching is configured — it is not). At a few thousand users this
is seconds per call.

**Mass mail.** Single-threaded executor, core = max = 1, queue capacity 10
(`configuration/AsyncConfiguration.java:38-40`) — the 11th concurrent campaign is rejected with
`TaskRejectedException`, which for a `void @Async` method is thrown to the *caller*
(`MassEmailApiController.java:79`) and surfaces as an unhandled 500. The whole recipient list is
resolved on the request thread and held in memory on the async thread
(`MassEmailApiController.java:73-79`); sending is a serial loop with one SMTP connection per
message (`EmailServiceImpl.java:807-831`) and no throttling — a plausible way to get the relay to
rate-limit or blacklist the platform.

**Event ingestion.** One consumer, two DB round-trips per event, plus a full walk of the SSE
emitter list for 12 event types (§6.3). The `events` table has indexes on `(userId, eventType)` and
`lastUpdate` (`events/ShanoirEvent.java:24-27`) but **none on `studyId`**, which is the sole
predicate of the only query endpoint (`ShanoirEventRepositoryImpl.java:86`) — a full scan of a
year's platform-wide events per page view, plus a second full scan for the count query (`:120-126`).

**SSE.** `EMITTERS` is a static `CopyOnWriteArrayList` (`tasks/AsyncTaskApiController.java:49`) with
an infinite timeout (`tasks/UserSseEmitter.java:24`) and no cap. Every write copies the array;
`keepConnectionAlive` walks the whole list every 30 s (`ShanoirEventsService.java:162-173`). It is
also static, so a multi-replica deployment would deliver notifications only to whichever replica
holds the connection — **the service cannot be horizontally scaled as written** (the daily cron and
the retention job have the same problem).

---

## 12. Technical debt inventory

| Rank | Item | Effort | Rationale |
|---|---|---|---|
| 1 | Missing `@PreAuthorize` on `AccessRequestApi` / `EventsApi` / `RoleApi` | S (1–2 d) | §9.1, §9.2 — security-critical, small diff |
| 2 | No DLQ / retry on any queue | M (3–5 d) | §9.5 — platform-wide, needs coordination |
| 3 | Java-serialization AMQP with trust-all | M (1 w) | §10 — switch to `Jackson2JsonMessageConverter`, must be rolled out to all services at once |
| 4 | Keycloak dual write without outbox or reconciliation | L (2–3 w) | §5 |
| 5 | Audit log is mutable + incomplete + unqueryable by user | L (2–3 w) | §6 — needs a data model split |
| 6 | Synchronous SMTP on request threads | M (1 w) | §11 |
| 7 | `@WebMvcTest` slices do not enforce method security | S (1 d) | §8.3 — copy the `MassEmailApiControllerTest` pattern; will surface real bugs |
| 8 | Zero tests for `events/`, `tasks/`, `configuration/amqp/`, `ShanoirUsersManagement` (~1,600 LOC) | L (2–3 w) | §8.2 |
| 9 | JPQL string concatenation | S (1 d) | §9.3 |
| 10 | Hard-coded DB credentials + master-realm Keycloak admin | S–M | §10 |
| 11 | Dead code: `getHash`, `ExtensionWithMotivationValidator`, 2 commented IT classes, 4 templates, `UserDTO`, `UserContext`, `ms_users_to_ms_studies_user_delete` | S (1 d) | §7 |
| 12 | `EmailServiceImpl` at 834 LOC with 8× duplicated blocks | M (1 w) | §7 |
| 13 | Static `EMITTERS` + `@Scheduled` prevent horizontal scaling | L | §11 |
| 14 | `spring.main.allow-circular-references: true` | S–M | §3.2 |
| 15 | `shanoir-events.log` `FileAppender` never rotates | XS (1 h) | §6.1 |
| 16 | Compose/entrypoint SMTP variable mismatch; image tag drift `2.12.0` vs `3.4.0` | XS | §9.13 |

---

## 13. Improvement roadmap

**Quick wins (< 1 day each)**

1. Add `@PreAuthorize` to all six `AccessRequestApi` methods, to `EventsApi.countPassedEvents`, and
   to `RoleApi.findRoles`. Remove `/users/count` and `/events/count` from the `permitAll` list
   unless a documented anonymous consumer exists.
2. Fix the SpEL precedence in `UserApi.java:153`; grep every `@PreAuthorize` in the repository for
   the same `or … and …` shape.
3. `KeycloakClient.java:155`: `keycloak` → `getKeycloak()`.
4. `ShanoirUsersManagement.java:191`: `search(...)` → `searchByUsername(..., true)`.
5. Replace the `searchField` and sort-property concatenation with an allow-list map
   (`ShanoirEventRepositoryImpl.java:72-74,98-100`).
6. Delete the eight `LOG.info(content)` calls; downgrade `EmailServiceImpl.java:673` to INFO and
   drop the address.
7. Add `@Transactional` to `deletePeriodically`; convert `shanoir-events.log` to a
   `RollingFileAppender`.
8. Null-check `originalEntity` in `FieldEditionSecurityManagerImpl.java:53`; add `user.setId(null)`
   in `AccountRequestApiController`.
9. Fix the `Comparator` (`AsyncTaskApiController.java:78`), the unboxing NPE
   (`AccessRequestApiController.java:205`), and the unguarded `.get()` (`:214`).
10. Delete `PasswordUtils.getHash`, `ExtensionWithMotivationValidator`, the two commented-out IT
    classes, the four dead templates, and the `ms_users_to_ms_studies_user_delete` publisher.
11. Add an index on `events.studyId`.
12. Fix the compose SMTP variable list for the `users` service; move the DB password to an env var.

**Medium (1–2 weeks)**

1. **Make e-mail asynchronous and durable.** Annotate `EmailService` methods `@Async` with a bounded
   pool + `AsyncUncaughtExceptionHandler`, or (better) persist an outbox row in the same transaction
   as the workflow write and drain it with retries. Add a per-recipient send record so a failed
   notification is visible instead of a log line.
2. **DLQ + retry for every queue.** `x-dead-letter-exchange` on each `Queue` bean, a bounded
   `RetryTemplate` on both container factories, and a DLQ-depth alert. Then remove the
   catch-all `AmqpRejectAndDontRequeueException` wrappers so genuinely transient failures retry.
3. **Method security in the test slices.** Extract the `MassEmailApiControllerTest.MethodSecurityConfiguration`
   pattern into a shared test config, apply it to all `@WebMvcTest`s, and write the full
   role × endpoint matrix. Budget for the bugs it uncovers.
4. **Keycloak reconciliation job.** Nightly: DB rows with `keycloak_id IS NULL`, Keycloak users with
   no DB row, and role/`enabled` divergence. Report as a `ShanoirEvent` and an admin e-mail. Reuse
   `getUsersEnabledStatus`.
5. **Audit-coverage pass.** Emit events for user create, account-request approve/deny, extension
   approve/deny, role change (with before/after), TOTP and enable/disable changes, password reset,
   and mass e-mail. Populate `studyId` where relevant so the events are actually reachable.
6. **Cover `events/`, `tasks/` and the AMQP listeners** with real tests, including a Testcontainers
   RabbitMQ round-trip for `receiveEvent`.
7. Replace cleartext-password e-mails with Keycloak `execute-actions-email` (UPDATE_PASSWORD).
8. Paginate `GET /users`; add `@EntityGraph`/batch fetching for `role` + `accountRequestInfo`.

**Large (refactors)**

1. **Migrate AMQP to JSON.** Register a `Jackson2JsonMessageConverter` bean in `ms-common`, convert
   the `Long`/`List<Long>` RPC payloads to explicit DTOs, and remove
   `SPRING_AMQP_DESERIALIZATION_TRUST_ALL` from all five entrypoints. Requires a coordinated
   platform release.
2. **Split the audit log from the task tracker.** Append-only `audit_events` (DB-generated id,
   insert-only, `source_service`, optional hash chain, configurable retention with archive-to-S3)
   plus a mutable `async_tasks` table for progress/SSE. Add an auditor query API
   (by user, by object, by type, by date range) with proper authorization.
3. **Extract the notification service.** `email/` + the six mail queues + the templates are a
   coherent bounded context that does not belong in the identity service. Extracting it removes
   `ms-common`'s e-mail DTOs from the users service and lets notifications scale independently.
4. **Introduce a transactional outbox for the Keycloak dual write**, and make user creation
   idempotent (natural key = username) so retries converge.
5. **Make the service horizontally scalable**: externalise SSE fan-out (Redis pub/sub or a
   `ShedLock`-guarded single emitter node) and put `ShedLock` on `@Scheduled` methods.
6. **Decompose `EmailServiceImpl`** into a `NotificationSender` (transport, from/reply-to, logging
   policy) plus one small class per notification family; the eight duplicated blocks collapse to a
   table of `(template, subject, variables)`.

---

## 14. Future work & feature directions

- **Delegate identity fully to Keycloak.** The dual-write problem exists because Shanoir keeps a
  parallel user table. A large but principled direction is to make Keycloak the sole system of
  record for profile data, keeping only a local `user_id ↔ keycloak_id` projection updated from
  Keycloak admin events. That deletes §5 entirely.
- **SSO / identity federation.** Academic deployments (OFSEP, Neurinfo) would benefit from
  eduGAIN/Shibboleth or Renater federation, which Keycloak supports natively. The blockers are the
  local `users` table (above) and the assumption that Shanoir owns password reset
  (`extensionrequest`, `ShanoirUsersManagement`).
- **ORCID linkage.** Add an ORCID iD to `User`, populate it via a Keycloak ORCID identity provider,
  and expose it in dataset/study provenance so exports and BIDS metadata carry proper researcher
  attribution.
- **Delegated administration.** Today the model is binary (platform ADMIN vs study
  `CAN_ADMINISTRATE`). A "centre administrator" or "study-group administrator" role would let
  large multi-centre projects self-manage account requests and expiry extensions without a platform
  admin, and would give the missing authorization predicate for §9.1.
- **Compliance-grade audit.** Beyond §13's split: tamper-evidence (hash chain or signed batches),
  a defined retention policy per event class, an export for regulators, and an "access to patient
  data" event class that records dataset/subject scope — today a data download is an event with a
  free-text message.
- **Account-request UX and anti-abuse.** E-mail verification before the account is created, CAPTCHA
  or proof-of-work on `/accountrequest`, rate limiting at nginx on the five anonymous routes, and
  a self-service password reset that goes through Keycloak instead of `/extensionrequest`.
- **Notification preferences.** Per-user opt-in/opt-out per notification class, an unsubscribe
  footer on mass mail, and a digest mode for high-volume study administrators.
- **Observability.** Micrometer counters for Keycloak call latency/failures, mail send
  success/failure, event ingestion lag and DLQ depth. None exist today.

---

## 15. Appendix

### 15.1 Largest files (main)

| LOC | File |
|---|---|
| 834 | `email/EmailServiceImpl.java` |
| 472 | `user/model/User.java` |
| 460 | `user/service/UserServiceImpl.java` |
| 385 | `user/utils/KeycloakClient.java` |
| 286 | `accessrequest/controller/AccessRequestApiController.java` |
| 282 | `ShanoirUsersManagement.java` |
| 233 | `user/service/UserService.java` (annotations, not logic) |
| 231 | `events/ShanoirEventLight.java` (getters) |
| 199 | `user/controller/UserApiController.java` |
| 197 | `events/ShanoirEventsService.java` |
| 186 | `utils/PasswordUtils.java` |
| 179 | `configuration/amqp/RabbitMQUserService.java` |

### 15.2 Complexity hotspots

| Method | Why |
|---|---|
| `ShanoirEventRepositoryImpl.find` (`:47-132`) | ~12 branches building two query strings by concatenation; the injection site |
| `EmailServiceImpl.notifyStudyManagerStudyUsersAdded` (`:552-606`) | two nested loops, each with a 15-line lambda, two null-conditionals |
| `UserServiceImpl.createAccountRequest` (`:307-345`) | 5 DB writes, 1 AMQP RPC, 2 SMTP sends, 1 Keycloak call, no transaction |
| `AccessRequestApiController.resolveNewAccessRequest` (`:170-211`) | 4 branches × 2 side-effecting subsystems, no transaction, no authorization |
| `ShanoirEventsService.addEvent` (`:57-78`) | a 12-clause `||` chain that should be a `Set<String>` constant |
| `KeycloakClient.updateUser` (`:336-358`) | non-atomic role remove/add inside one swallowing try/catch |
| `AbstractUserRequestApiController.generateUsername` (`:75-107`) | nested split loops + an unbounded DB probe loop |

### 15.3 TODO / FIXME / XXX / HACK inventory

**Empty.** `rg 'TODO|FIXME|XXX|HACK'` over `shanoir-ng-users/src` returns nothing. Note this is not
the same as "no debt" — the dead code and commented-out logic of §7 carry no marker
(`ExtensionWithMotivationValidator.java:37-40`, `UserApiControllerITTest.java`,
`RoleApiControllerITTest.java`, `UserServiceSecurityTest.java:102-113`). The only markers in the
service's deployment surface are outside `src`: `docker-compose/users/entrypoint:28`
(`#FIXME: why can't we use an env var here?`) and `:70` (`# FIXME: does the alias need to match the
host name ?`).

### 15.4 Dependency observations

- `pom.xml:48-52` pulls **`io.jsonwebtoken:jjwt:0.7.0`** — released 2016, pinned, and superseded by
  the split `jjwt-api`/`jjwt-impl`/`jjwt-jackson` artifacts since 0.10. It is not imported by any
  class in the module (`rg 'io.jsonwebtoken'` finds no usage) and should be removed. Old jjwt
  versions carry known signature-verification advisories.
- `pom.xml:55-58` declares Gson under an `<!-- AMQP -->` comment; the AMQP code uses Jackson
  exclusively. Unused.
- `com.icegreen:greenmail:2.0.0-alpha-3` (`pom.xml:69-78`) — an **alpha** build used as the test
  SMTP server, with a manual `jakarta.activation` exclusion. Move to a stable 2.x.
- `shanoir-ng-study-rights` is a compile dependency (`pom.xml:61-65`), which is what gives this
  service its own replica of the study-rights table and the `StudyUser` entity. It is a real
  coupling, not just a utility jar.
- No explicit `junit-vintage-engine`, yet two test classes use JUnit 4 runners (§8.1).
- `spring.threads.virtual.enabled: true` (`application.yml:56`) with Java 21 + JDBC + JavaMail:
  pinning risk (§11). Worth measuring before relying on it.
- Deployment images are pinned to `NG_v2.12.0` (`docker-compose.yml:129`) while the poms say
  `3.4.0`.
