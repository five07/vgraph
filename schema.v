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
	// type_name: the declared type of an alias or enum, such as `Email`; the
	// type is declared in the struct's module
	type_name   string
	enum_values []string // an enum's values, in order
	embedded    string   // the embedded struct (mixin) the field is from
	json_type   string   // a JSON field's V type (`Field.json`)
	// GraphQL options (`Field`)
	graphql_skip_in []GraphqlSkip
	order_field     string
	directives      []string
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
	// indexes: the ones its `indexes()` declares
	indexes []Index
	// view: the struct reads from a view (`@[vgraph: 'view']`): it has no writes
	view bool
	// how many hooks, interceptors and privacy rules its model declares
	hooks        int
	interceptors int
	rules        int
	// graphql: the options its `graphql()` gives
	graphql GraphqlTable
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
	// Inline: a generic call on `field.typ` generates C that doesn't compile
	// (regressions/comptime_generic_call.vv); a nested `$for` over its fields
	// doesn't.
	mut columns := []Column{}
	mut edges := []Edge{}
	mut options := []Field{}
	mut hooks := []Hook{}
	mut interceptors := []Interceptor{}
	mut indexes := []Index{}
	mut policy := Policy{}
	mut gql := GraphqlTable{}
	record := T{}
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
			// relation fields are not columns
		} $else $if field.is_embed {
			// a mixin: its columns, and its edges, options, hooks, interceptors,
			// indexes and policy, before the table's own
			$for sub in field.typ.fields {
				$if sub.typ is $array || sub.typ is $map {
				} $else {
					mut typ := 'other'
					mut type_name := ''
					mut enum_values := []string{}
					$if sub.typ is ?i8 {
						typ = '?i8'
					} $else $if sub.typ is ?i16 {
						typ = '?i16'
					} $else $if sub.typ is ?int {
						typ = '?int'
					} $else $if sub.typ is ?i64 {
						typ = '?i64'
					} $else $if sub.typ is ?u8 {
						typ = '?u8'
					} $else $if sub.typ is ?u16 {
						typ = '?u16'
					} $else $if sub.typ is ?u32 {
						typ = '?u32'
					} $else $if sub.typ is ?u64 {
						typ = '?u64'
					} $else $if sub.typ is ?f32 {
						typ = '?f32'
					} $else $if sub.typ is ?f64 {
						typ = '?f64'
					} $else $if sub.typ is ?bool {
						typ = '?bool'
					} $else $if sub.typ is ?string {
						typ = '?string'
					} $else $if sub.typ is ?time.Time {
						typ = '?time.Time'
					} $else $if sub.unaliased_typ is i8 {
						typ = 'i8'
					} $else $if sub.unaliased_typ is i16 {
						typ = 'i16'
					} $else $if sub.unaliased_typ is int {
						typ = 'int'
					} $else $if sub.unaliased_typ is i64 {
						typ = 'i64'
					} $else $if sub.unaliased_typ is u8 {
						typ = 'u8'
					} $else $if sub.unaliased_typ is u16 {
						typ = 'u16'
					} $else $if sub.unaliased_typ is u32 {
						typ = 'u32'
					} $else $if sub.unaliased_typ is u64 {
						typ = 'u64'
					} $else $if sub.unaliased_typ is f32 {
						typ = 'f32'
					} $else $if sub.unaliased_typ is f64 {
						typ = 'f64'
					} $else $if sub.unaliased_typ is bool {
						typ = 'bool'
					} $else $if sub.unaliased_typ is string {
						typ = 'string'
					} $else $if sub.unaliased_typ is time.Time {
						typ = 'time.Time'
					} $else $if sub.typ is $enum {
						typ = 'enum'
						$for v in sub.typ.values {
							enum_values << v.name
						}
					}
					$if sub.typ is $alias || sub.typ is $enum {
						type_name = typeof(sub.typ).name.all_after_last('.')
					}
					columns << new_column(sub.name, sub.attrs, typ, type_name, enum_values, '${field.name}')
				}
			}
			$for method in field.typ.methods {
				$if method.name == 'edges' {
					edges << record.$(field.name).$method()
				} $else $if method.name == 'fields' {
					options << record.$(field.name).$method()
				} $else $if method.name == 'hooks' {
					hooks << record.$(field.name).$method()
				} $else $if method.name == 'interceptors' {
					interceptors << record.$(field.name).$method()
				} $else $if method.name == 'indexes' {
					indexes << record.$(field.name).$method()
				} $else $if method.name == 'policy' {
					policy = policy.merged(record.$(field.name).$method())
				}
			}
		} $else $if field.typ is $struct && field.unaliased_typ !is time.Time && field.typ !is ?time.Time {
			// a relation
		} $else {
			mut typ := 'other'
			mut type_name := ''
			mut enum_values := []string{}
			$if field.typ is ?i8 {
				typ = '?i8'
			} $else $if field.typ is ?i16 {
				typ = '?i16'
			} $else $if field.typ is ?int {
				typ = '?int'
			} $else $if field.typ is ?i64 {
				typ = '?i64'
			} $else $if field.typ is ?u8 {
				typ = '?u8'
			} $else $if field.typ is ?u16 {
				typ = '?u16'
			} $else $if field.typ is ?u32 {
				typ = '?u32'
			} $else $if field.typ is ?u64 {
				typ = '?u64'
			} $else $if field.typ is ?f32 {
				typ = '?f32'
			} $else $if field.typ is ?f64 {
				typ = '?f64'
			} $else $if field.typ is ?bool {
				typ = '?bool'
			} $else $if field.typ is ?string {
				typ = '?string'
			} $else $if field.typ is ?time.Time {
				typ = '?time.Time'
			} $else $if field.unaliased_typ is i8 {
				typ = 'i8'
			} $else $if field.unaliased_typ is i16 {
				typ = 'i16'
			} $else $if field.unaliased_typ is int {
				typ = 'int'
			} $else $if field.unaliased_typ is i64 {
				typ = 'i64'
			} $else $if field.unaliased_typ is u8 {
				typ = 'u8'
			} $else $if field.unaliased_typ is u16 {
				typ = 'u16'
			} $else $if field.unaliased_typ is u32 {
				typ = 'u32'
			} $else $if field.unaliased_typ is u64 {
				typ = 'u64'
			} $else $if field.unaliased_typ is f32 {
				typ = 'f32'
			} $else $if field.unaliased_typ is f64 {
				typ = 'f64'
			} $else $if field.unaliased_typ is bool {
				typ = 'bool'
			} $else $if field.unaliased_typ is string {
				typ = 'string'
			} $else $if field.unaliased_typ is time.Time {
				typ = 'time.Time'
			} $else $if field.typ is $enum {
				typ = 'enum'
				$for v in field.typ.values {
					enum_values << v.name
				}
			}
			$if field.typ is $alias || field.typ is $enum {
				type_name = typeof(field.typ).name.all_after_last('.')
			}
			columns << new_column(field.name, field.attrs, typ, type_name, enum_values, '')
		}
	}
	$for method in T.methods {
		$if method.name == 'edges' {
			edges << record.$method()
		} $else $if method.name == 'fields' {
			options << record.$method()
		} $else $if method.name == 'hooks' {
			hooks << record.$method()
		} $else $if method.name == 'interceptors' {
			interceptors << record.$method()
		} $else $if method.name == 'indexes' {
			indexes << record.$method()
		} $else $if method.name == 'policy' {
			policy = policy.merged(record.$method())
		} $else $if method.name == 'graphql' {
			gql = record.$method()
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
	mut view := false
	$for attr in T.attributes {
		if attr.name == 'graphql' && attr.has_arg && attr.arg.trim(" '") == '-' {
			skip = true
		}
		if attr.name == 'vgraph' && attr.has_arg && attr.arg.trim(" '") == 'view' {
			view = true
		}
	}
	s.order << name
	s.options[name] = options
	s.hooks[name] = hooks
	s.interceptors[name] = interceptors
	s.policies[name] = policy
	s.tables[name] = Table{
		name:         name
		struct_:      T.name
		key:          load.primary_key[T]()
		columns:      columns
		edges:        edges
		indexes:      indexes
		graphql_skip: skip
		view:         view
		hooks:        hooks.len
		interceptors: interceptors.len
		rules:        policy.query.len + policy.mutation.len
		graphql:      gql
	}
}

// new_column returns the column of a field, with its V type `typ` (such as
// `?i64` or `enum`), as `add` reflected it.
fn new_column(field string, attrs []string, typ string, type_name string, enum_values []string, embedded string) Column {
	serial := is_serial(attrs)
	column := load.column_name(field, attrs)
	return Column{
		// a mixin's column is named as V's ORM names it: `Stamps.created_at`
		name:         if embedded != '' { '${embedded}.${column}' } else { column }
		field:        field
		typ:          typ
		kind:         match typ.trim_left('?') {
			'int' { ColumnKind.int }
			'i64' { ColumnKind.i64 }
			'string' { ColumnKind.string }
			else { ColumnKind.other }
		}
		nullable:     typ.starts_with('?')
		sql_type:     sql_type_of(attrs)
		graphql_skip: is_graphql_skip(attrs)
		serial:       serial
		optional:     serial || typ.starts_with('?')
		unique:       'unique' in attrs
		type_name:    type_name
		enum_values:  enum_values
		embedded:     embedded
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
		if table.graphql.node {
			key := table.column(table.key) or { Column{} }
			if key.typ != 'i64' || !key.serial {
				problems << '${name}.graphql: `node` needs an i64 serial key, which `global_ids` gives a range to'
			}
		}
		for index in table.indexes {
			for column in index.columns {
				if _ := table.column(column) {
				} else {
					problems << '${name}.indexes: `${column}` is not a column'
				}
			}
		}
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
			check_edge_options(mut problems, at, s, table, edge, target)
			if edge.order_field != '' {
				if edge.kind !in [.many_to_one, .one_to_one] {
					problems << '${at}: `order_field` is for a many_to_one or one_to_one edge'
				} else if _ := target.column(edge.order_field) {
				} else {
					problems << '${at}: `order_field` names `${edge.to}.${edge.order_field}`, which does not exist'
				}
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

// check_edge_options reports what is wrong with an edge's `ref`, `bidi`,
// `required` and `immutable`, and with the join struct of an edge schema.
fn check_edge_options(mut problems []string, at string, s Schema, table Table, edge Edge, target Table) {
	if edge.ref != '' {
		mut inverse := ?Edge(none)
		for e in target.edges {
			if e.name == edge.ref {
				inverse = e
			}
		}
		if inv := inverse {
			unique := ['one_to_many', 'one_to_one']
			ok := inv.to == table.name && match edge.kind {
				.one_to_many, .one_to_one {
					inv.kind == .many_to_one && inv.column == edge.column
						&& inv.type_col == edge.type_col && inv.type_val == edge.type_val
				}
				.many_to_one {
					inv.kind.str() in unique && inv.column == edge.column
						&& inv.type_col == edge.type_col && inv.type_val == edge.type_val
				}
				.many_to_many {
					inv.kind == .many_to_many && inv.through == edge.through
						&& inv.column == edge.through_to && inv.through_to == edge.column
				}
			} && (inv.ref == '' || inv.ref == edge.name)
			if !ok {
				problems << '${at}: `ref` names `${edge.to}.${edge.ref}`, which is not its other side'
			}
		} else {
			problems << '${at}: `ref` names `${edge.to}.${edge.ref}`, which does not exist'
		}
	}
	if edge.unique && edge.kind != .many_to_one {
		problems << '${at}: `unique` is for a many_to_one edge; a one_to_one edge is unique already'
	}
	if edge.bidi {
		if edge.to != table.name || edge.kind !in [.many_to_one, .many_to_many] {
			problems << '${at}: `bidi` is for a many_to_one or many_to_many edge to its own table'
		} else if edge.kind == .many_to_one {
			if !edge.unique {
				problems << '${at}: a `bidi` many_to_one edge pairs rows one to one: set `unique`'
			}
			if column := table.column(edge.column) {
				if !column.nullable {
					problems << '${at}: `bidi` needs `${table.name}.${edge.column}` to be nullable'
				}
			}
		}
	}
	if edge.required && edge.kind != .many_to_one {
		problems << '${at}: `required` is for a many_to_one edge'
	}
	if edge.kind == .many_to_many {
		if join := s.tables[edge.through] {
			// an edge schema: the join table is a struct of its own
			for name in [edge.column, edge.through_to] {
				if _ := join.column(name) {
				} else {
					problems << '${at}: the join struct `${edge.through}` has no column `${name}`'
				}
			}
		}
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
