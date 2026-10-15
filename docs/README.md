# vgraph guides

1. [Getting started](getting-started.md): install, declare models, generate the
   client, first queries.
2. [Schema](schema.md): fields, edges, field options, mixins, enums, JSON, views,
   indexes and global ids.
3. [Queries](queries.md): predicates, eager loading, traversals, aggregates and
   orders, and the queries that never grow with the rows.
4. [Writes](writes.md): builders, edges, validation, upserts.
5. [Transactions](transactions.md): `tx`, callbacks, and what runs in one.
6. [Hooks, interceptors and privacy](hooks-and-privacy.md): the rules of who
   reads and writes what.
7. [GraphQL](graphql.md): the generated schema and server, connections,
   mutations, your own fields, page sizes, introspection.
8. [Migrations](migrations.md): what the schema gives `v.migrations`.
9. [Drivers](drivers.md): SQLite and PostgreSQL, and plain ORM connections.
10. [Tracing](tracing.md): OpenTelemetry spans of operations, models and
    statements, by each model's level, without their values.
11. [Differences from Ent](differences-from-ent.md).

The code in these guides comes from [`snippets/`](snippets), a project that
compiles and runs it in its tests, so it can't drift from vgraph: its blog
(users, articles, comments and tags) is in `snippets/models/models.v`. The
[examples](../examples) go further: every relationship kind
([relations](../examples/relations)), a whole API ([service](../examples/service)),
the same API traced ([service-otel](../examples/service-otel)),
[pagination](../examples/pagination) and [auth](../examples/auth).

API reference: `v doc -f html -m -o api .` in the repository (its
`.vdocignore` leaves out the examples), or the doc comments in the source.
