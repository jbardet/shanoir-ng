Shanoir-ng migrations directory
===============================

SQL migrations scripts are stored as: `<DB_NAME>/<SEQ_NUMBER>_<DESCRIPTION>.sql` and included in the
*database* Docker image.

They can be applied on an existing Shanoir-NG instance by running the *database* container with
`SHANOIR_MIGRATION=manual` or `SHANOIR_MIGRATION=auto`. See the `shanoir-entrypoint.sh` script for
more details.

Migrations are applied in the alphebetical order. Collisions on sequence number may arise (if two
migrations are created independently on two different branches), but are not problematic. The main
point is to ensure that they are applied in a deterministic order.

Important: migrations are tracked by their filename. **Do not rename a migration after a release**
(or the existing shanoir-ng instances would attempt to apply it a second time).

## Pair entity changes with SQL migrations

Production microservices run with `spring.jpa.hibernate.ddl-auto: validate`. A new or
changed `@Entity` field therefore requires a matching SQL script in this directory
**in the same pull request**.

Fresh installs (`SHANOIR_MIGRATION=init`) create the schema from Hibernate and will
not catch a missing migration. Upgrades (`SHANOIR_MIGRATION=auto`) apply only these
SQL scripts. If the script is missing, the microservice fails at startup with a
schema-validation error.

When adding a migration, pick the next free sequence number in the target database
folder (see `check_migration_names.py`). Verify the SQL column name, type, and length
match the JPA mapping (for example `offlineToken` → `offline_token VARCHAR(2000)`).
