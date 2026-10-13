module vgraph

import v.migrations

// Migration helpers: what the schema's edges need from the database, as
// `v.migrations` values, for migrations written by hand. A migration that
// takes them from the current schema creates what the edges need now; later
// migrations that add edges add only what those edges need.

// migration_indexes returns the indexes that the schema's edges need, once
// each, sorted by name, for `ctx.add_index`:
// - one_to_many and one_to_one: on the target's `column`, after `type_col` for
//   a polymorphic edge. A one_to_one edge's index is unique, unless the edge
//   has `soft_del` (a deleted target keeps its key) or another edge needs the
//   same columns without it.
// - many_to_many: on the join table's `column`, and a unique index on its two
//   columns, so that a pair is stored once.
// - many_to_one: none; it looks targets up by their primary key.
//
// Each is named `<table>_<columns>_idx`.
pub fn (s Schema) migration_indexes() []migrations.Index {
	mut found := map[string]migrations.Index{}
	for table in s.tables() {
		for edge in table.edges {
			mut needed := []migrations.Index{}
			match edge.kind {
				.one_to_many, .one_to_one {
					columns := if edge.type_col != '' {
						[edge.type_col, edge.column]
					} else {
						[edge.column]
					}
					needed << new_index(edge.to, columns, edge.kind == .one_to_one
						&& edge.soft_del == '')
				}
				.many_to_many {
					needed << new_index(edge.through, [edge.column], false)
					mut pair := [edge.column, edge.through_to]
					pair.sort()
					needed << new_index(edge.through, pair, true)
				}
				.many_to_one {}
			}
			for index in needed {
				if existing := found[index.name] {
					if existing.unique != index.unique {
						// one edge needs it unique, another doesn't: it can't be
						found[index.name] = migrations.Index{
							...index
							unique: false
						}
						continue
					}
				}
				found[index.name] = index
			}
		}
	}
	mut names := found.keys()
	names.sort()
	return names.map(found[it])
}

fn new_index(table string, columns []string, unique bool) migrations.Index {
	return migrations.Index{
		name:    '${table}_${columns.join('_')}_idx'
		table:   table
		columns: columns
		unique:  unique
	}
}

// foreign_keys returns a foreign key for each column that holds a key of one
// table, once each, sorted by name: the column of a many_to_one edge, or of a
// one_to_many or one_to_one edge's target, and both columns of a join table.
// A polymorphic edge's column holds keys of several tables, so it gets none.
// Each is named `<table>_<column>_fkey`.
//
// SQLite can't add a foreign key to a table that exists: there, put a table's
// keys (those with its `from_table`) in the `migrations.Table` that creates it.
// Tables created from structs with `migrations.create_orm_table` take theirs
// from the ORM's `@[references]` attribute instead.
pub fn (s Schema) foreign_keys() ![]migrations.ForeignKey {
	s.validate()!
	// the columns that polymorphic edges use, as `table.column`
	mut polymorphic := map[string]bool{}
	for table in s.tables() {
		for edge in table.edges {
			if edge.type_col == '' {
				continue
			}
			match edge.kind {
				.one_to_many, .one_to_one { polymorphic['${edge.to}.${edge.column}'] = true }
				.many_to_one { polymorphic['${table.name}.${edge.column}'] = true }
				.many_to_many {}
			}
		}
	}
	mut found := map[string]migrations.ForeignKey{}
	for table in s.tables() {
		for edge in table.edges {
			target := s.table(edge.to)!
			keys := match edge.kind {
				.one_to_many, .one_to_one { [new_foreign_key(edge.to, edge.column, table)] }
				.many_to_one { [new_foreign_key(table.name, edge.column, target)] }
				.many_to_many { join_foreign_keys(table, edge, target) }
			}
			for key in keys {
				if '${key.from_table}.${key.column}' !in polymorphic {
					found[key.name] = key
				}
			}
		}
	}
	mut names := found.keys()
	names.sort()
	return names.map(found[it])
}

fn new_foreign_key(from string, column string, to Table) migrations.ForeignKey {
	return migrations.ForeignKey{
		name:        '${from}_${column}_fkey'
		from_table:  from
		column:      column
		to_table:    to.name
		primary_key: to.key
	}
}

fn join_foreign_keys(table Table, edge Edge, target Table) []migrations.ForeignKey {
	return [new_foreign_key(edge.through, edge.column, table),
		new_foreign_key(edge.through, edge.through_to, target)]
}

// join_table returns the join table of the many_to_many edge `edge` of
// `table`, for `ctx.create_table`: an `id`, the edge's two columns, not null and
// typed as the keys they hold, and a foreign key on each. Its indexes come from
// `migration_indexes`. A join table that has a struct can be created from it
// with `migrations.create_orm_table` instead.
//
// A key is an `integer`, a `bigint` or `text` column, or a `uuid` one when its
// field has `sql_type: 'uuid'`.
pub fn (s Schema) join_table(table string, edge string) !migrations.Table {
	s.validate()!
	from := s.table(table)!
	e := s.edge(table, edge)!
	if e.kind != .many_to_many {
		return error('`${table}.${edge}` is ${e.kind}; only a many_to_many edge has a join table')
	}
	target := s.table(e.to)!
	return migrations.Table{
		name:         e.through
		columns:      [key_column(e.column, from), key_column(e.through_to, target)]
		foreign_keys: join_foreign_keys(from, e, target)
	}
}

// key_column returns a not-null column `name` that holds keys of `table`.
fn key_column(name string, table Table) migrations.Column {
	key := table.column(table.key) or { Column{} }
	kind := if key.sql_type.to_lower().starts_with('uuid') {
		migrations.ColumnType.uuid
	} else {
		match key.kind {
			.int { migrations.ColumnType.integer }
			.i64 { migrations.ColumnType.bigint }
			else { migrations.ColumnType.text }
		}
	}
	return migrations.Column{
		name:     name
		kind:     kind
		nullable: false
	}
}

// add_edge_indexes checks the schema `s`, and adds each of its
// `migration_indexes()`, for a migration's `up`. The tables must exist, and
// the indexes must not.
pub fn add_edge_indexes(mut ctx migrations.Context, s Schema) ! {
	s.validate()!
	for index in s.migration_indexes() {
		ctx.add_index(index)!
	}
}

// remove_edge_indexes removes each of `s.migration_indexes()`, for the `down`
// of a migration that added them with `add_edge_indexes`.
pub fn remove_edge_indexes(mut ctx migrations.Context, s Schema) ! {
	for index in s.migration_indexes().reverse() {
		ctx.remove_index(index.table, index.name)!
	}
}
