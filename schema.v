module vgraph

import load
import time

// ColumnKind is what vgraph needs to know about a column's type to check edges.
// Keys, and the columns that hold them, are `int`, `i64` or `string`.
pub enum ColumnKind {
	int
	i64
	string
	other
}

// Column is one column of a registered table.
pub struct Column {
pub:
	name     string // the column, such as `owner_id`
	field    string // the struct field stored in it
	typ      string // the field's V type, such as `?time.Time`, or `other`
	kind     ColumnKind
	nullable bool
	// sql_type is the field's `sql_type` attribute, such as `uuid`, or empty.
	sql_type string
	// graphql_skip leaves the column out of the GraphQL schema: the field has
	// `@[graphql: '-']`, or its options say so.
	graphql_skip bool
	// serial: the database sets the column, a `@[sql: serial]` key.
	serial bool
	// optional: a create may leave the column unset. It is nullable, serial,
	// has a default, or is marked optional.
	optional bool
	// the field's options (`Field`), as data
	immutable   bool
	sensitive   bool
	unique      bool // `@[unique]`, or the `unique` option
	comment     string
	deprecated  string
	has_default bool // a default on create
	auto_update bool // a default on update
}

// Table is a registered struct: its table, key, columns (in field order) and
// declared edges.
pub struct Table {
pub:
	name    string
	struct_ string // the struct's name, such as `models.Article`
	key     string
	columns []Column
	edges   []Edge
	// graphql_skip leaves the table out of the GraphQL schema: the struct has
	// `@[graphql: '-']`.
	graphql_skip bool
}

// column returns the column `name`, or `none` when the table has none.
pub fn (t Table) column(name string) ?Column {
	for column in t.columns {
		if column.name == name {
			return column
		}
	}
	return none
}

// Schema holds the registered tables. Add each struct with `add`, then pass the
// schema to `Client.new`, which checks it.
pub struct Schema {
mut:
	tables map[string]Table
	order  []string
	// the options each table's `fields()` gave, and its hooks, interceptors
	// and policy, kept apart from `tables`, which `vgraph gen` prints as JSON:
	// functions can't be printed
	options      map[string][]Field
	hooks        map[string][]Hook
	interceptors map[string][]Interceptor
	policies     map[string]Policy
}

// tables returns the registered tables, in the order they were added.
pub fn (s Schema) tables() []Table {
	return s.order.map(s.tables[it])
}

// add registers the struct `T`: its table, its columns, and the edges its
// `edges()` method returns, if it has one.
pub fn (mut s Schema) add[T]() ! {
	name := load.table_name[T]()
	if name in s.tables {
		return error('table `${name}` is registered twice')
	}
	mut columns := []Column{}
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
			// relation fields are not columns
		} $else {
			// Inline: a generic call on `field.typ` generates C that doesn't
			// compile (regressions/comptime_generic_call.vv).
			mut typ := 'other'
			$if field.typ is int {
				typ = 'int'
			} $else $if field.typ is ?int {
				typ = '?int'
			} $else $if field.typ is i64 {
				typ = 'i64'
			} $else $if field.typ is ?i64 {
				typ = '?i64'
			} $else $if field.typ is f64 {
				typ = 'f64'
			} $else $if field.typ is ?f64 {
				typ = '?f64'
			} $else $if field.typ is bool {
				typ = 'bool'
			} $else $if field.typ is ?bool {
				typ = '?bool'
			} $else $if field.typ is string {
				typ = 'string'
			} $else $if field.typ is ?string {
				typ = '?string'
			} $else $if field.typ is time.Time {
				typ = 'time.Time'
			} $else $if field.typ is ?time.Time {
				typ = '?time.Time'
			}
			serial := is_serial(field.attrs)
			columns << Column{
				name:         load.column_name(field.name, field.attrs)
				field:        field.name
				typ:          typ
				kind:         match typ.trim_left('?') {
					'int' { ColumnKind.int }
					'i64' { ColumnKind.i64 }
					'string' { ColumnKind.string }
					else { ColumnKind.other }
				}
				nullable:     typ.starts_with('?')
				sql_type:     sql_type_of(field.attrs)
				graphql_skip: is_graphql_skip(field.attrs)
				serial:       serial
				optional:     serial || typ.starts_with('?')
				unique:       'unique' in field.attrs
			}
		}
	}
	mut edges := []Edge{}
	mut options := []Field{}
	$for method in T.methods {
		$if method.name == 'edges' {
			record := T{}
			edges = record.$method()
		} $else $if method.name == 'fields' {
			record := T{}
			options = record.$method()
		} $else $if method.name == 'hooks' {
			record := T{}
			s.hooks[name] = record.$method()
		} $else $if method.name == 'interceptors' {
			record := T{}
			s.interceptors[name] = record.$method()
		} $else $if method.name == 'policy' {
			record := T{}
			s.policies[name] = record.$method()
		}
	}
	for i, column in columns {
		for o in options {
			if o.name == column.field {
				columns[i] = column.with_options(o)
			}
		}
	}
	mut skip := false
	$for attr in T.attributes {
		if attr.name == 'graphql' && attr.has_arg && attr.arg.trim(" '") == '-' {
			skip = true
		}
	}
	s.order << name
	s.options[name] = options
	s.tables[name] = Table{
		name:         name
		struct_:      T.name
		key:          load.primary_key[T]()
		columns:      columns
		edges:        edges
		graphql_skip: skip
	}
}

// is_graphql_skip reports whether a field's attributes include
// `@[graphql: '-']`.
fn is_graphql_skip(attrs []string) bool {
	for attr in attrs {
		if attr.starts_with('graphql:') && attr.all_after('graphql:').trim(" '") == '-' {
			return true
		}
	}
	return false
}

// is_serial reports whether a field's attributes include `@[sql: serial]`.
fn is_serial(attrs []string) bool {
	for attr in attrs {
		if attr.starts_with('sql:') && attr.all_after('sql:').trim(" '") == 'serial' {
			return true
		}
	}
	return false
}

// options returns the options that `table`'s `fields()` gives, by field name.
pub fn (s Schema) options(table string) map[string]Field {
	mut found := map[string]Field{}
	for o in s.options[table] or { [] } {
		found[o.name] = o
	}
	return found
}

// sql_type_of returns the value of a field's `sql_type` attribute, or ''.
fn sql_type_of(attrs []string) string {
	for attr in attrs {
		if attr.starts_with('sql_type:') {
			return attr.all_after('sql_type:').trim(" '")
		}
	}
	return ''
}

// table returns the registered table `name`.
pub fn (s Schema) table(name string) !Table {
	return s.tables[name] or { error('no table `${name}` is registered') }
}

// edge returns the edge `name` declared by the table `table`.
pub fn (s Schema) edge(table string, name string) !Edge {
	for edge in s.table(table)!.edges {
		if edge.name == name {
			return edge
		}
	}
	return error('`${table}` has no edge `${name}`')
}

// validate checks every edge against the registered tables, and returns every
// problem it finds in one error, one per line.
pub fn (s Schema) validate() ! {
	mut problems := []string{}
	for name in s.order {
		table := s.tables[name]
		check_options(mut problems, table, s.options[name] or { [] })
		mut seen := map[string]bool{}
		for edge in table.edges {
			at := '${name}.${edge.name}'
			if edge.name == '' {
				problems << '${name}: an edge has no name'
			} else if edge.name in seen {
				problems << '${at}: declared twice'
			}
			seen[edge.name] = true
			target := s.tables[edge.to] or {
				problems << '${at}: no table `${edge.to}` is registered'
				continue
			}
			// the table whose rows hold `column`, the one `type_col` filters, and
			// the one whose key `column` holds
			holder, keyed := match edge.kind {
				.one_to_many, .one_to_one { target, table }
				.many_to_one { table, target }
				.many_to_many { Table{}, table }
			}
			key_kind := key_kind_of(mut problems, at, keyed) or { continue }
			if edge.kind == .many_to_many {
				if edge.through == '' || edge.through_to == '' {
					problems << '${at}: a many_to_many edge needs `through` and `through_to`'
				}
				if edge.type_col != '' {
					check_column(mut problems, at, target, edge.type_col, .string, 'type_col')
				}
			} else {
				check_column(mut problems, at, holder, edge.column, key_kind, 'column')
				if edge.type_col != '' {
					check_column(mut problems, at, holder, edge.type_col, .string, 'type_col')
				}
			}
			if (edge.type_col == '') != (edge.type_val == '') {
				problems << '${at}: `type_col` and `type_val` go together'
			}
			if edge.soft_del != '' {
				if column := target.column(edge.soft_del) {
					if !column.nullable {
						problems << '${at}: `soft_del` names `${edge.to}.${edge.soft_del}`, which is not nullable'
					}
				} else {
					problems << '${at}: `soft_del` names `${edge.to}.${edge.soft_del}`, which does not exist'
				}
			}
		}
	}
	if problems.len > 0 {
		return error(problems.join('\n'))
	}
}

// key_kind_of returns the kind of `table`'s key, and reports a key that edges
// can't use.
fn key_kind_of(mut problems []string, at string, table Table) ?ColumnKind {
	key := table.column(table.key) or {
		problems << '${at}: `${table.name}` has no key column `${table.key}`'
		return none
	}
	if key.kind == .other {
		problems << '${at}: the key `${table.name}.${key.name}` is ${key.typ}; edges need an int, i64 or string key'
		return none
	}
	return key.kind
}

fn check_column(mut problems []string, at string, table Table, name string, kind ColumnKind, role string) {
	column := table.column(name) or {
		problems << '${at}: `${role}` names `${table.name}.${name}`, which does not exist'
		return
	}
	if column.kind != kind {
		article := if kind == .int || kind == .i64 { 'an' } else { 'a' }
		problems << '${at}: `${role}` names `${table.name}.${name}`, which is not ${article} ${kind} column'
	}
}
