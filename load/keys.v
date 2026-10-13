module load

import orm

// Keys can be `int`, `i64` or `string` (such as a UUID). Loads carry them as
// strings, their `str()` form, so one code path serves every key type, and turn
// them back into the column's type for each query.

// KeyType is the type of a key column.
pub enum KeyType {
	int
	i64
	string
}

// key_type returns the type of `T`'s field stored in `column`, which must be an
// `int`, `i64` or `string`, or an option of one.
pub fn key_type[T](column string) !KeyType {
	$for field in T.fields {
		$if field.typ is int || field.typ is ?int {
			if column_name(field.name, field.attrs) == column {
				return .int
			}
		} $else $if field.typ is i64 || field.typ is ?i64 {
			if column_name(field.name, field.attrs) == column {
				return .i64
			}
		} $else $if field.typ is string || field.typ is ?string {
			if column_name(field.name, field.attrs) == column {
				return .string
			}
		}
	}
	return error('`${table_name[T]()}.${column}` is not an int, i64 or string column')
}

// key_column returns the value of `row`'s key field stored in `column`, an
// `int`, `i64` or `string` or an option of one, as a string. It returns `none`
// when there is no such field, or it is null.
pub fn key_column[T](row T, column string) ?string {
	$for field in T.fields {
		$if field.typ is int || field.typ is i64 || field.typ is string {
			if column_name(field.name, field.attrs) == column {
				return row.$(field.name).str()
			}
		} $else $if field.typ is ?int {
			if column_name(field.name, field.attrs) == column {
				if value := row.$(field.name) {
					return value.str()
				}
				return none
			}
		} $else $if field.typ is ?i64 {
			if column_name(field.name, field.attrs) == column {
				if value := row.$(field.name) {
					return value.str()
				}
				return none
			}
		} $else $if field.typ is ?string {
			if column_name(field.name, field.attrs) == column {
				if value := row.$(field.name) {
					return value
				}
				return none
			}
		}
	}
	return none
}

// in_keys returns the condition `column IN (keys)`, with `keys` in their string
// form converted to `typ`. An empty `keys` matches no row.
pub fn in_keys(column string, keys []string, typ KeyType) Cond {
	return match typ {
		.int { in_ints(column, keys.map(it.int())) }
		.i64 { in_i64s(column, keys.map(it.i64())) }
		.string { in_strings(column, keys) }
	}
}

// link_pairs returns the `[from_col, to_col]` pairs of the join table `table`
// whose `from_col` is one of `ids`, as strings, in one query, or none without a
// query when `ids` is empty. `from` and `to` are the types of the two columns.
pub fn link_pairs(conn orm.Connection, table string, from_col string, to_col string, ids []string, from KeyType, to KeyType) ![][]string {
	if ids.len == 0 {
		return [][]string{}
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table
		}
		has_where:    true
		primary:      from_col
		fields:       [from_col, to_col]
		select_exprs: [from_col, to_col]
		types:        [orm_type(from), orm_type(to)]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, where_of([in_keys(from_col, ids, from)]))!
	mut pairs := [][]string{cap: rows.len}
	for row in rows {
		pairs << [cell_key(row[0], from_col)!, cell_key(row[1], to_col)!]
	}
	return pairs
}

fn orm_type(typ KeyType) int {
	return match typ {
		.int { orm.type_idx['int'] }
		.i64 { orm.type_idx['i64'] }
		.string { orm.type_string }
	}
}

// cell_key returns a selected key cell as a string.
fn cell_key(cell orm.Primitive, name string) !string {
	return match cell {
		int { cell.str() }
		i64 { cell.str() }
		string { cell }
		else { error('`${name}`: expected a key, got ${cell.type_name()}') }
	}
}
