module vgraph

// Index is an index that loading an edge needs: on the columns its `IN` query
// filters by, the type column first for a polymorphic edge.
pub struct Index {
pub:
	name    string
	table   string
	columns []string
}

// sql returns the statement that creates the index when it is missing. It works
// on SQLite and PostgreSQL; MySQL has no `CREATE INDEX IF NOT EXISTS`.
pub fn (i Index) sql() string {
	columns := i.columns.map('"${it}"').join(', ')
	return 'CREATE INDEX IF NOT EXISTS "${i.name}" ON "${i.table}" (${columns})'
}

// indexes returns the indexes that the schema's edges need, once each, sorted by
// name. A many_to_one edge needs none: it looks targets up by primary key.
pub fn (s Schema) indexes() []Index {
	mut found := map[string]Index{}
	for table in s.tables() {
		for edge in table.edges {
			index := match edge.kind {
				.one_to_many {
					columns := if edge.type_col != '' {
						[edge.type_col, edge.column]
					} else {
						[edge.column]
					}
					new_index(edge.to, columns)
				}
				.many_to_many {
					new_index(edge.through, [edge.column])
				}
				.many_to_one {
					continue
				}
			}
			found[index.name] = index
		}
	}
	mut names := found.keys()
	names.sort()
	return names.map(found[it])
}

fn new_index(table string, columns []string) Index {
	return Index{
		name:    '${table}_${columns.join('_')}_idx'
		table:   table
		columns: columns
	}
}

// ensure_indexes creates each of `schema.indexes()` that is missing, and
// returns them all.
//
// It is temporary: vgraph is built against V master, and until a V release
// includes `v.migrations`, this keeps edge loads indexed. Phase 5 replaces it
// with `v.migrations` steps (PLAN.md, Q13 and Q10).
pub fn (c Client) ensure_indexes() ![]Index {
	indexes := c.schema.indexes()
	mut conn := c.conn
	for index in indexes {
		conn.execute(index.sql())!
	}
	return indexes
}
