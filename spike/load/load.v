module load

import orm

// load_many loads, in one query, the `C` rows whose `fk` column holds the primary
// key of one of `parents`, keyed by that parent's key. Parents with no rows have no
// entry, and repeated parent keys are queried once.
pub fn load_many[P, C](conn orm.Connection, parents []P, fk string) !map[int][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[int][]C{}
	if ids.len == 0 {
		return grouped
	}
	rows := orm.new_query[C](conn).where('${fk} IN ?', ids)!.query()!
	for row in rows {
		key := int_column[C](row, fk) or { return error('`${fk}` is not an int column') }
		grouped[key] << row
	}
	return grouped
}

// keys_of returns the distinct primary keys of `rows`, in their first order.
pub fn keys_of[T](rows []T) ![]int {
	key := primary_key[T]()
	mut seen := map[int]bool{}
	mut ids := []int{cap: rows.len}
	for row in rows {
		id := int_column[T](row, key) or { return error('`${key}` is not an int column') }
		if id !in seen {
			seen[id] = true
			ids << id
		}
	}
	return ids
}

// primary_key returns the column name of `T`'s `@[primary]` field, or `id`.
pub fn primary_key[T]() string {
	$for field in T.fields {
		if 'primary' in field.attrs {
			return column_name(field.name, field.attrs)
		}
	}
	return 'id'
}

// int_column returns the value of the int field of `row` whose column is `column`.
pub fn int_column[T](row T, column string) ?int {
	$for field in T.fields {
		$if field.typ is int {
			if column_name(field.name, field.attrs) == column {
				return row.$(field.name)
			}
		}
	}
	return none
}

// column_name returns the column a field is stored in: its `@[sql: 'name']`
// attribute when it has one, or else its name.
fn column_name(name string, attrs []string) string {
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
