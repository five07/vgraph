# TODO

- polymorphic FKs on related tables
- optional pagination with GraphQl standard (by config): 
  - first, after, offest
  - edges, node, cursor, pageInfo (hasNextPage, endCursor)
  - new example `pagination` to show both methods
  - https://graphql.org/learn/pagination/
- hooks example
  - passing JWT bearer token
  - hook handler to evaluate access/deny to resources
- schema discovery and validation
- federation
- OTel integration
- docs section
- upstream fix in `vlib/orm` (PLAN.md Q51 (d), future state): an optional
  `orm.RawConnection` interface (`exec_raw(query, params []Primitive) ![][]Primitive`,
  `dialect()`), implemented by the SQLite, PostgreSQL and MySQL drivers through their
  typed bind paths (`sqlite_stmt_binder`, `pg_stmt_binder`), so raw SQL gets typed
  params, NULL and typed results; then drop vgraph's SQLite/PostgreSQL adapters
