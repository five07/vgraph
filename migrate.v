module vgraph

import v.migrations

// Migration helpers: what the schema's edges need from the database, as
// `v.migrations` values, for migrations written by hand. A migration that
// takes them from the current schema creates what the edges need now; later
// migrations that add edges add only what those edges need.

// Index is an index a struct declares in its `indexes()` method, beside
// `edges()`: on its columns, unique or not, and partial with `where`.
pub struct Index {
pub:
	// name: `<table>_<columns>_idx` when empty
	name    string
	columns []string @[required]
	unique  bool
	// where: a partial index's condition, in SQL, such as `deleted_at IS NULL`
	where string
}

// migration_indexes returns the indexes that the schema's edges need, once
// each, sorted by name, for `ctx.add_index`:
// - one_to_many and one_to_one: on the target's `column`, after `type_col` for
//   a polymorphic edge. A one_to_one edge's index is unique, unless the edge
//   has `soft_del` (a deleted target keeps its key) or another edge needs the
//   same columns without it.
// - many_to_many: on the join table's `column`, and a unique index on its two
//   columns, so that a pair is stored once.
// - many_to_one: none, as it looks targets up by their primary key; but a
//   unique one gets a unique index on its column, as the key side of a
//   one-to-one relationship.
//
// A field whose options (`fields()`) say `unique` gets a unique index too.
// Each is named `<table>_<columns>_idx`.
pub fn (s Schema) migration_indexes() []migrations.Index {
	mut found := map[string]migrations.Index{}
	for table in s.tables() {
		for edge in table.edges {
			// a view has no indexes
			holder := match edge.kind {
				.one_to_many, .one_to_one { edge.to }
				.many_to_many { edge.through }
				.many_to_one { table.name }
			}
			if t := s.tables[holder] {
				if t.view {
					continue
				}
			}
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
				.many_to_one {
					// the key side of a one-to-one relationship
					if edge.unique {
						columns := if edge.type_col != '' {
							[edge.type_col, edge.column]
						} else {
							[edge.column]
						}
						needed << new_index(table.name, columns, true)
					}
				}
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
	// declared indexes, but partial ones (`partial_indexes`)
	for table in s.tables() {
		for index in table.indexes {
			if index.where == '' && !table.view {
				i := declared_index(table, index)
				found[i.name] = i
			}
		}
	}
	// unique fields; a unique index serves an edge too
	for table in s.tables() {
		for o in s.options[table.name] or { [] } {
			if !o.unique {
				continue
			}
			for column in table.columns {
				if column.field == o.name {
					index := new_index(table.name, [column.name], true)
					found[index.name] = index
				}
			}
		}
	}
	mut names := found.keys()
	names.sort()
	return names.map(found[it])
}

fn declared_index(table Table, index Index) migrations.Index {
	i := new_index(table.name, index.columns, index.unique)
	return migrations.Index{
		...i
		name: if index.name != '' { index.name } else { i.name }
	}
}

// PartialIndex is a declared index with a condition, which `v.migrations`
// can't create: `add_edge_indexes` writes its SQL.
pub struct PartialIndex {
pub:
	index migrations.Index
	where string
}

// partial_indexes returns the declared indexes that have a `where`, sorted by
// name.
pub fn (s Schema) partial_indexes() []PartialIndex {
	mut found := []PartialIndex{}
	for table in s.tables() {
		for index in table.indexes {
			if index.where != '' && !table.view {
				found << PartialIndex{
					index: declared_index(table, index)
					where: index.where
				}
			}
		}
	}
	found.sort(a.index.name < b.index.name)
	return found
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
				from_view := if t := s.tables[key.from_table] { t.view } else { false }
				to_view := if t := s.tables[key.to_table] { t.view } else { false }
				if '${key.from_table}.${key.column}' !in polymorphic && !from_view && !to_view {
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
	for p in s.partial_indexes() {
		i := p.index
		unique := if i.unique { 'UNIQUE ' } else { '' }
		ctx.execute('CREATE ${unique}INDEX ${quote_name(i.name)} ON ${quote_name(i.table)} (${i.columns.map(quote_name(it)).join(', ')}) WHERE ${p.where}')!
	}
}

fn quote_name(name string) string {
	return '"${name.replace('"', '""')}"'
}

// remove_edge_indexes removes each of `s.migration_indexes()`, for the `down`
// of a migration that added them with `add_edge_indexes`.
pub fn remove_edge_indexes(mut ctx migrations.Context, s Schema) ! {
	for p in s.partial_indexes().reverse() {
		ctx.execute('DROP INDEX ${quote_name(p.index.name)}')!
	}
	for index in s.migration_indexes().reverse() {
		ctx.remove_index(index.table, index.name)!
	}
}

// migration_table returns the table of the struct registered as `table`, for
// `ctx.create_table`: its key an auto-incrementing `id` (`AUTOINCREMENT` on
// SQLite, `BIGSERIAL` on PostgreSQL), as `global_ids` needs, and its other
// columns typed as V's ORM stores them, with the foreign keys
// `foreign_keys()` gives it.
pub fn (s Schema) migration_table(table string) !migrations.Table {
	s.validate()!
	t := s.table(table)!
	mut columns := []migrations.Column{}
	for c in t.columns {
		if c.name == t.key {
			continue
		}
		sql := c.sql_type.to_lower()
		kind := match true {
			sql.starts_with('uuid') { migrations.ColumnType.uuid }
			sql.starts_with('jsonb') { migrations.ColumnType.jsonb }
			else {
				match c.typ.trim_left('?') {
					'bool' { migrations.ColumnType.boolean }
					'i64', 'u32', 'u64', 'enum' { migrations.ColumnType.bigint }
					'i8', 'i16', 'int', 'u8', 'u16' { migrations.ColumnType.integer }
					'f32' { migrations.ColumnType.real }
					'f64' { migrations.ColumnType.double_precision }
					'time.Time' { migrations.ColumnType.timestamp }
					else { migrations.ColumnType.text }
				}
			}
		}
		columns << migrations.Column{
			name:     c.name
			kind:     kind
			nullable: c.nullable
			unique:   if c.unique { ?bool(true) } else { none }
		}
	}
	return migrations.Table{
		name:         t.name
		columns:      columns
		id_name:      t.key
		foreign_keys: s.foreign_keys()!.filter(it.from_table == t.name)
	}
}

// create_table creates the table of the struct registered as `table`, as
// `migration_table` describes it: its key auto-incrementing, as `global_ids`
// needs. It writes the SQL itself, as `v.migrations` refuses the column names
// V's ORM gives a mixin's fields (`Stamps.created_at`).
pub fn create_table(mut ctx migrations.Context, s Schema, table string) ! {
	t := s.migration_table(table)!
	pg := ctx.dialect == .pg
	mut parts := [if pg {
		'${quote_name(t.id_name)} BIGSERIAL PRIMARY KEY'
	} else {
		'${quote_name(t.id_name)} INTEGER PRIMARY KEY AUTOINCREMENT'
	}]
	for c in t.columns {
		typ := match c.kind {
			.boolean { 'BOOLEAN' }
			.integer { 'INTEGER' }
			.bigint { 'BIGINT' }
			.real { 'REAL' }
			.double_precision { 'DOUBLE PRECISION' }
			.timestamp { 'TIMESTAMP' }
			.jsonb {
				if pg { 'JSONB' } else { 'TEXT' }
			}
			.uuid {
				if pg { 'UUID' } else { 'TEXT' }
			}
			else { 'TEXT' }
		}
		mut column := '${quote_name(c.name)} ${typ}'
		if !(c.nullable or { true }) {
			column += ' NOT NULL'
		}
		if c.unique or { false } {
			column += ' UNIQUE'
		}
		parts << column
	}
	for key in t.foreign_keys {
		parts << 'CONSTRAINT ${quote_name(key.name)} FOREIGN KEY (${quote_name(key.column)}) REFERENCES ${quote_name(key.to_table)} (${quote_name(key.primary_key)})'
	}
	ctx.execute('CREATE TABLE ${quote_name(t.name)} (${parts.join(', ')})')!
}

// global_ids gives each table with an `i64` serial key its own range of keys,
// as Ent's globally unique ids: the table with index `n` (from 1) in
// `vgraph_types` counts from `n << 32`, so a key names its table
// (`Client.table_of`). A
// table gets the next index the first time a migration calls it; indexes never
// move. On SQLite a table must have been created with `AUTOINCREMENT`, and on
// PostgreSQL its key must be a `BIGSERIAL`: `create_table` does both.
pub fn global_ids(mut ctx migrations.Context, s Schema) ! {
	s.validate()!
	ctx.execute('CREATE TABLE IF NOT EXISTS vgraph_types (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)')!
	mut known := map[string]int{}
	// from 1, so that a global id is always past 2^32, and never a plain one
	mut next := 1
	for row in ctx.execute('SELECT id, name FROM vgraph_types')! {
		index := row.vals[0].int()
		known[row.vals[1]] = index
		if index >= next {
			next = index + 1
		}
	}
	for t in s.tables() {
		key := t.column(t.key) or { continue }
		if !key.serial || key.typ != 'i64' || t.view || t.name in known {
			continue
		}
		index := next
		next++
		start := i64(index) << 32
		name := t.name.replace("'", "''")
		match ctx.dialect {
			.sqlite {
				ddl := ctx.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '${name}'")!
				if ddl.len == 0 || !ddl[0].vals[0].to_upper().contains('AUTOINCREMENT') {
					return error('`${t.name}`: global ids need its key to be AUTOINCREMENT on SQLite: create the table with `vgraph.create_table`')
				}
				ctx.execute("DELETE FROM sqlite_sequence WHERE name = '${name}'")!
				ctx.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('${name}', ${start})")!
			}
			.pg {
				ctx.execute("SELECT setval(pg_get_serial_sequence('${quote_name(t.name).replace("'", "''")}', '${t.key}'), ${start + 1}, false)") or {
					return error('`${t.name}`: global ids need its key to be a BIGSERIAL on PostgreSQL: ${err.msg()}')
				}
			}
			else {
				return error('global ids run on SQLite and PostgreSQL')
			}
		}
		ctx.execute("INSERT INTO vgraph_types (id, name) VALUES (${index}, '${name}')")!
	}
}

// polymorphic_check_name returns the name of the trigger, and on PostgreSQL
// of its function, that checks the polymorphic pair `p`:
// `<table>_<column>_poly`.
fn polymorphic_check_name(p Polymorphic) string {
	return '${p.table}_${p.column}_poly'
}

// polymorphic_missing returns a condition, on the row being written (`NEW`),
// that is true when its pair `p` names no row: the key column is set, and no
// target of the type the type column names has that key. A type no edge
// declares names no row.
fn (s Schema) polymorphic_missing(p Polymorphic) !string {
	mut types := p.targets.keys()
	types.sort()
	mut parts := []string{}
	for typ in types {
		target := s.table(p.targets[typ])!
		parts << "SELECT 1 FROM ${quote_name(target.name)} WHERE NEW.${quote_name(p.type_col)} = '${typ.replace("'", "''")}' AND ${quote_name(target.name)}.${quote_name(target.key)} = NEW.${quote_name(p.column)}"
	}
	return 'NEW.${quote_name(p.column)} IS NOT NULL AND NOT EXISTS (${parts.join(' UNION ALL ')})'
}

// add_polymorphic_checks checks the schema `s`, and adds, for each of its
// `polymorphics()`, a trigger that checks the pair on insert and on an update
// of either column, for a migration's `up`, on SQLite and PostgreSQL: the key
// column must be null or name a row of the table the type column names. The
// writes check this already (`Client.create`); the triggers are for an app
// that also writes outside vgraph. They see rows as the database has them: a
// soft-deleted target still counts, and a deleted target leaves its
// references as they are.
//
// A failed check aborts the statement with `<table>.<column>: no row of the
// type in <type_col> has this key`; on PostgreSQL its SQLSTATE is 23503
// (`foreign_key_violation`).
pub fn add_polymorphic_checks(mut ctx migrations.Context, s Schema) ! {
	s.validate()!
	for p in s.polymorphics() {
		name := polymorphic_check_name(p)
		missing := s.polymorphic_missing(p)!
		message := '${p.table}.${p.column}: no row of the type in ${p.type_col} has this key'.replace("'", "''")
		columns := '${quote_name(p.type_col)}, ${quote_name(p.column)}'
		match ctx.dialect {
			.sqlite {
				for event in ['INSERT', 'UPDATE OF ${columns}'] {
					suffix := if event == 'INSERT' { 'insert' } else { 'update' }
					ctx.execute("CREATE TRIGGER ${quote_name('${name}_${suffix}')} BEFORE ${event} ON ${quote_name(p.table)} WHEN ${missing} BEGIN SELECT RAISE(ABORT, '${message}'); END")!
				}
			}
			.pg {
				ctx.execute("CREATE FUNCTION ${quote_name(name)}() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN IF ${missing} THEN RAISE EXCEPTION '${message}' USING ERRCODE = 'foreign_key_violation'; END IF; RETURN NEW; END \$\$")!
				ctx.execute('CREATE TRIGGER ${quote_name(name)} BEFORE INSERT OR UPDATE OF ${columns} ON ${quote_name(p.table)} FOR EACH ROW EXECUTE FUNCTION ${quote_name(name)}()')!
			}
			else {
				return error('polymorphic checks run on SQLite and PostgreSQL')
			}
		}
	}
}

// remove_polymorphic_checks removes the triggers of `add_polymorphic_checks`,
// and on PostgreSQL their functions, for the `down` of a migration that added
// them.
pub fn remove_polymorphic_checks(mut ctx migrations.Context, s Schema) ! {
	for p in s.polymorphics().reverse() {
		name := polymorphic_check_name(p)
		match ctx.dialect {
			.sqlite {
				ctx.execute('DROP TRIGGER IF EXISTS ${quote_name('${name}_update')}')!
				ctx.execute('DROP TRIGGER IF EXISTS ${quote_name('${name}_insert')}')!
			}
			.pg {
				ctx.execute('DROP TRIGGER IF EXISTS ${quote_name(name)} ON ${quote_name(p.table)}')!
				ctx.execute('DROP FUNCTION IF EXISTS ${quote_name(name)}()')!
			}
			else {
				return error('polymorphic checks run on SQLite and PostgreSQL')
			}
		}
	}
}
