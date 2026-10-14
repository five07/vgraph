# Migrations

vgraph doesn't run migrations: V's `v.migrations` does, from migrations you
write, and records them in `schema_migrations`. vgraph gives them what the
schema needs:

<!-- snippet: docs/snippets/setup.v#migration -->
```v
// initial creates the tables from the schema `vgraph gen` wrote, then the
// join table, the indexes the edges need, and each table's range of global ids.
const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      fn (mut ctx migrations.Context) ! {
		s := graph.schema()!
		for table in ['users', 'articles', 'comments', 'tags'] {
			vgraph.create_table(mut ctx, s, table)!
		}
		ctx.create_table(s.join_table('articles', 'tags')!)!
		vgraph.add_edge_indexes(mut ctx, s)!
		vgraph.global_ids(mut ctx, s)!
	}
	down:    fn (mut ctx migrations.Context) ! {
		for table in ['article_tags', 'comments', 'tags', 'articles', 'users', 'vgraph_types'] {
			ctx.drop_table(table)!
		}
	}
}
```

- `vgraph.create_table(mut ctx, schema, table)`: a model's table, with an
  auto-incrementing key (`AUTOINCREMENT` on SQLite, `BIGSERIAL` on PostgreSQL) and
  its foreign keys. `schema.migration_table(table)` is the same as a
  `migrations.Table`; `migrations.create_orm_table[T]` works too, without global
  ids.
- `schema.join_table(table, edge)`: a many_to_many edge's join table.
- `vgraph.add_edge_indexes(mut ctx, schema)` and `remove_edge_indexes`: an index
  on each column an edge load filters by (unique for a one_to_one edge), a unique
  index on each join table's pair, the `unique` fields' and the declared ones
  (`indexes()`, partial too). `schema.migration_indexes()` lists them.
- `schema.foreign_keys()`: a foreign key on each column that holds one table's
  keys; none on a polymorphic edge's, which holds several tables' keys.
- `vgraph.add_polymorphic_checks(mut ctx, schema)` and
  `remove_polymorphic_checks`: a trigger on each polymorphic pair, on SQLite and
  PostgreSQL, that checks on insert and update that the key names a row of the
  table the type names, for apps that also write outside vgraph. The triggers
  see rows as stored: a soft-deleted target still counts, and deleting a target
  leaves its references.
- `vgraph.global_ids(mut ctx, schema)`: each table with an `i64` serial key gets
  its own range of keys, recorded in `vgraph_types`.

A migration that has run is never changed: a schema change is a new migration.
The helpers take the schema as it is when a migration runs, so a migration that
uses them makes what the edges need at that time; a later migration that adds
edges adds their indexes itself, and the earlier one should then list the
indexes it made, so a new database gets the same.

SQLite can't add a foreign key to a table that exists: put a table's keys in the
statement that creates it (`create_table` does). `v.migrations` runs on
PostgreSQL through a direct connection (`pg.connect_direct`), not a pool.
