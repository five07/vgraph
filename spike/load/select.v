module load

import orm

// select_in returns the `T` rows whose `column` is one of `ids`, in one query. It
// calls `orm.Connection.select` directly instead of `orm.new_query`, which leaves
// the standard library after 2027-08-17. Only int, i64, f64, bool and string fields
// are mapped so far.
pub fn select_in[T](mut conn orm.Connection, column string, ids []int) ![]T {
	mut fields := []string{}
	mut types := []int{}
	$for field in T.fields {
		fields << column_name(field.name, field.attrs)
		types << field.typ
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table_name[T]()
		}
		has_where:    true
		fields:       fields
		select_exprs: fields
		types:        types
	}
	where := orm.QueryData{
		fields: [column]
		data:   [orm.Primitive(ids)]
		types:  [typeof[[]int]().idx]
		kinds:  [.in]
	}
	rows := conn.select(config, orm.QueryData{}, where)!
	mut result := []T{cap: rows.len}
	for row in rows {
		mut value := T{}
		mut i := 0
		$for field in T.fields {
			cell := row[i]
			$if field.typ is int {
				value.$(field.name) = match cell {
					int { cell }
					i64 { int(cell) }
					else { return error('`${field.name}`: expected an int') }
				}
			} $else $if field.typ is i64 {
				value.$(field.name) = match cell {
					i64 { cell }
					int { i64(cell) }
					else { return error('`${field.name}`: expected an i64') }
				}
			} $else $if field.typ is f64 {
				value.$(field.name) = cell as f64
			} $else $if field.typ is bool {
				value.$(field.name) = match cell {
					bool { cell }
					int { cell != 0 }
					else { return error('`${field.name}`: expected a bool') }
				}
			} $else $if field.typ is string {
				value.$(field.name) = cell as string
			} $else {
				return error('`${field.name}`: this field type is not mapped yet')
			}
			i++
		}
		result << value
	}
	return result
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
