# Differences from Ent

vgraph follows [Ent](https://entgo.io) and [entgql](https://entgo.io/docs/graphql):
its names, its edge kinds, its builders, hooks, interceptors and privacy rules,
and entgql's GraphQL conventions. Where it differs:

- **Models are V structs** for V's ORM, with methods beside them, rather than a
  schema package: `edges()`, `fields()`, `hooks()`, `interceptors()`, `policy()`,
  `indexes()`, `graphql()`. Field types come from the struct; `fields()` only adds
  options.
- **Edges name their columns.** An edge says which column holds the key
  (`column`, and `through` / `through_to` for a join table), since the tables are
  V's ORM's, not generated.
- **A `limit` in an eager load is per parent.** `with_comments(... .limit(3))`
  loads each article's three newest comments, in one query; Ent's limits the
  whole load.
- **Polymorphic edges** (`type_col` / `type_val`) are built in, and their keys
  are checked on write.
- **No migrations of its own.** V's `v.migrations` runs migrations you write;
  vgraph gives them tables, indexes, foreign keys, triggers and global ids. There
  is no auto-migration.
- **A GraphQL server of its own.** The generated server runs on vgraph's
  `graphql` module, not gqlgen; it is tested against graphql-js. Lists without
  `relay: true` take `limit` and `offset`, which entgql doesn't have, and every
  list and connection can have a default and a largest page size.
- **Writes and hooks**: a hook on a model is untyped (the model can't import the
  generated module); typed hooks are registered on the graph. Rules registered on
  the graph run before the model's.
- **Not there yet:** field-level privacy, bytes fields (`[]u8`), OpenTelemetry
  and Apollo Federation, and MySQL in the drivers (it works through the ORM's
  connection).
