module load

import orm
import time

// select_in returns the `T` records whose `column` is one of `ids`, in one query,
// narrowed by `opts.type_col` and `opts.soft_del`. It calls
// `orm.Connection.select` directly: `orm.new_query`, which could do this, leaves
// the standard library after 2027-08-17 (PLAN.md, Q17). Fields may be `int`,
// `i64`, `f64`, `bool`, `string` or `time.Time`, or options of those.
pub fn select_in[T](conn orm.Connection, column string, ids []int, opts Options) ![]T {
	mut fields := []string{}
	mut types := []int{}
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
			// relation fields are not columns
		} $else {
			fields << column_name(field.name, field.attrs)
			// Inline: `column_type[field.typ]()` generates C that doesn't compile
			// (regressions/comptime_generic_call_test.v).
			$if field.typ is int || field.typ is ?int {
				types << orm.type_idx['int']
			} $else $if field.typ is i64 || field.typ is ?i64 {
				types << orm.type_idx['i64']
			} $else $if field.typ is f64 || field.typ is ?f64 {
				types << orm.type_idx['f64']
			} $else $if field.typ is bool || field.typ is ?bool {
				types << orm.type_idx['bool']
			} $else $if field.typ is string || field.typ is ?string {
				types << orm.type_string
			} $else $if field.typ is time.Time || field.typ is ?time.Time {
				types << orm.time_
			} $else {
				return error('`${field.name}`: vgraph cannot load this field type yet')
			}
		}
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table_name[T]()
		}
		has_where:    true
		primary:      primary_key[T]()
		fields:       fields
		select_exprs: fields
		types:        types
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, where_in(column, ids, opts))!
	mut result := []T{cap: rows.len}
	for row in rows {
		result << map_row[T](row)!
	}
	return result
}

// select_pairs returns the `[from_col, to_col]` pairs of the join table `table`
// whose `from_col` is one of `ids`, in one query.
fn select_pairs(conn orm.Connection, table string, from_col string, to_col string, ids []int) ![][]int {
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table
		}
		has_where:    true
		primary:      from_col
		fields:       [from_col, to_col]
		select_exprs: [from_col, to_col]
		types:        [orm.type_idx['int'], orm.type_idx['int']]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, where_in(from_col, ids, Options{}))!
	mut pairs := [][]int{cap: rows.len}
	for row in rows {
		pairs << [cell_int(row[0], from_col)!, cell_int(row[1], to_col)!]
	}
	return pairs
}

// where_in returns `column IN (ids)`, and `type_col = type_val` and
// `soft_del IS NULL` when `opts` has them.
fn where_in(column string, ids []int, opts Options) orm.QueryData {
	mut where := orm.QueryData{
		fields: [column]
		data:   [orm.Primitive(ids)]
		types:  [typeof[[]int]().idx]
		kinds:  [.in]
	}
	if opts.type_col != '' {
		where.fields << opts.type_col
		where.data << orm.Primitive(opts.type_val)
		where.types << orm.type_string
		where.kinds << .eq
		where.is_and << true
	}
	if opts.soft_del != '' {
		// IS NULL takes no value
		where.fields << opts.soft_del
		where.kinds << .is_null
		where.is_and << true
	}
	return where
}

// map_row builds a `T` from the cells of one selected row, in field order.
fn map_row[T](row []orm.Primitive) !T {
	mut value := T{}
	mut i := 0
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
		} $else {
			cell := row[i]
			i++
			$if field.typ is int {
				value.$(field.name) = cell_int(cell, field.name)!
			} $else $if field.typ is ?int {
				value.$(field.name) = if cell is orm.Null {
					?int(none)
				} else {
					?int(cell_int(cell, field.name)!)
				}
			} $else $if field.typ is i64 {
				value.$(field.name) = cell_i64(cell, field.name)!
			} $else $if field.typ is f64 {
				value.$(field.name) = cell as f64
			} $else $if field.typ is bool {
				value.$(field.name) = cell_int(cell, field.name)! != 0
			} $else $if field.typ is string {
				value.$(field.name) = cell as string
			} $else $if field.typ is ?string {
				value.$(field.name) = if cell is orm.Null {
					?string(none)
				} else {
					?string(cell as string)
				}
			} $else $if field.typ is time.Time {
				value.$(field.name) = cell as time.Time
			} $else $if field.typ is ?time.Time {
				value.$(field.name) = if cell is orm.Null {
					?time.Time(none)
				} else {
					?time.Time(cell as time.Time)
				}
			} $else {
				return error('`${field.name}`: vgraph cannot load this field type yet')
			}
		}
	}
	return value
}

fn cell_int(cell orm.Primitive, name string) !int {
	return match cell {
		int { cell }
		i64 { int(cell) }
		bool { int(cell) }
		else { error('`${name}`: expected an int, got ${cell.type_name()}') }
	}
}

fn cell_i64(cell orm.Primitive, name string) !i64 {
	return match cell {
		i64 { cell }
		int { i64(cell) }
		else { error('`${name}`: expected an i64, got ${cell.type_name()}') }
	}
}

// table_name returns `T`'s `@[table: 'name']` attribute, or else its struct name.
pub fn table_name[T]() string {
	$for attr in T.attributes {
		if attr.name == 'table' && attr.has_arg {
			return attr.arg.trim("'")
		}
	}
	return T.name.all_after_last('.')
}

// column_name returns the column a field is stored in: its `@[sql: 'name']`
// attribute when it has one, or else its name.
pub fn column_name(name string, attrs []string) string {
	for attr in attrs {
		if attr.starts_with('sql:') {
			value := attr.all_after('sql:').trim(" '")
			if value !in ['serial', 'i8', 'i16', 'int', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32',
				'f64', 'bool', 'string'] {
				return value
			}
		}
	}
	return name
}
