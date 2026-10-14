# Drivers

vgraph runs on V's `orm.Connection`, so the client reads through the SQLite,
PostgreSQL and MySQL adapters. Some of what vgraph does needs SQL the ORM can't
build, so `five07.vgraph.sqlite` and `five07.vgraph.pg` wrap V's connections in
drivers that run it with parameters; every ORM call passes through.

<!-- snippet: docs/snippets/drivers_test.v#drivers -->
```v
db := sqlite.connect(':memory:')!
// on vgraph's driver: everything
with_driver := graph.Graph.new(vsqlite.new(db))!
// on the ORM's connection alone: reads and simple writes, without what
// needs vgraph's SQL (upserts, i64 keys read back, several orders)
plain := graph.Graph.new(db)!
```

On PostgreSQL: `pg.pool(db)` on a pool (a transaction holds one connection until
it ends), or `pg.direct(conn)` on one connection.

What needs a driver:

- reading back a new key with `RETURNING`: an `i64` key, or any key on a bulk
  create (a plain connection reads `int` keys from `last_id()`, and a string key
  must be set, or have a default);
- upserts (`ON CONFLICT`), and one insert for a bulk create on PostgreSQL;
- several orders, orders by an edge, nulls first or last, locks, raw SQL,
  `group_by`, and per-parent limits cut by the database;
- Relay connections ordered by anything but the key.

Without one, the rest works: a subquery runs first as a query of its own, a
per-parent limit is cut in V, and a query that needs a driver fails with an error
that names them. Without `orm.TransactionalConnection`, statements run one by
one, not in a transaction.

The drivers pass values as text, stored as V's ORM stores them (on SQLite, times
as Unix seconds). The SQLite driver keeps SQL out of its error messages. SQLite
has one transaction per connection, so threads that share a driver take turns at
them.
