module vgraph

import load
import time

// ColumnKind is what vgraph needs to know about a column's type to check edges.
pub enum ColumnKind {
	int
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
			columns << Column{
				name:     load.column_name(field.name, field.attrs)
				field:    field.name
				typ:      typ
				kind:     match typ.trim_left('?') {
					'int' { ColumnKind.int }
					'string' { ColumnKind.string }
					else { ColumnKind.other }
				}
				nullable: typ.starts_with('?')
			}
		}
	}
	mut edges := []Edge{}
	$for method in T.methods {
		$if method.name == 'edges' {
			record := T{}
			edges = record.$method()
		}
	}
	s.order << name
	s.tables[name] = Table{
		name:    name
		struct_: T.name
		key:     load.primary_key[T]()
		columns: columns
		edges:   edges
	}
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
			// the table whose rows hold `column`, and the one `type_col` filters
			holder := match edge.kind {
				.one_to_many { target }
				.many_to_one { table }
				.many_to_many { Table{} }
			}
			if edge.kind == .many_to_many {
				if edge.through == '' || edge.through_to == '' {
					problems << '${at}: a many_to_many edge needs `through` and `through_to`'
				}
				if edge.type_col != '' {
					check_column(mut problems, at, target, edge.type_col, .string, 'type_col')
				}
			} else {
				check_column(mut problems, at, holder, edge.column, .int, 'column')
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

fn check_column(mut problems []string, at string, table Table, name string, kind ColumnKind, role string) {
	column := table.column(name) or {
		problems << '${at}: `${role}` names `${table.name}.${name}`, which does not exist'
		return
	}
	if column.kind != kind {
		problems << '${at}: `${role}` names `${table.name}.${name}`, which is not an ${kind} column'
	}
}
