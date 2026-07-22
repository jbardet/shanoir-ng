## Summary

<!-- What does this PR change, and why? -->

## Database migrations

Production microservices use `spring.jpa.hibernate.ddl-auto: validate`. Upgrades apply
schema changes only through SQL scripts in
`docker-compose/database-migrations/db-changes/`.

- [ ] This PR does **not** change any `@Entity` / JPA schema
- [ ] This PR changes JPA schema and includes a matching `db-changes/<ms>/NNNN_*.sql`
      migration in the **same PR** (column name, type, and length match the entity)
- [ ] N/A (documentation / CI / front-end only)

If you added or changed an entity field, confirm you tested an **upgrade** path
(`SHANOIR_MIGRATION=auto` on an existing database), not only a fresh install
(`SHANOIR_MIGRATION=init`).

## Test plan

- [ ] <!-- how you verified the change -->
