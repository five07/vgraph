// Package load loads the records at the other end of an edge for many records at
// once: one query per edge, never one per record.
module load

import orm

// Poly names the type column of a polymorphic edge, such as a comment's
// `owner_type`, and the value that selects one target, such as `Article`.
@[params]
pub struct Poly {
pub:
	type_col string
	type_val string
}

// load_one returns the `P` records that `children` refer to through their `fk`
// column, keyed by the `P` primary key, in one query. Children whose `fk` is
// null, and repeated keys, are skipped. With `poly`, only the children whose
// `poly.type_col` is `poly.type_val` are followed. Soft-deleted records are
// included, since the children still refer to them.
pub fn load_one[C, P](conn orm.Connection, children []C, fk string, poly Poly) !map[int]P {
	mut ids := []int{}
	mut seen := map[int]bool{}
	for child in children {
		if poly.type_col != '' {
			type_val := string_column[C](child, poly.type_col) or {
				return error('`${poly.type_col}` is not a string column')
			}
			if type_val != poly.type_val {
				continue
			}
		}
		id := int_column[C](child, fk) or { continue }
		if id !in seen {
			seen[id] = true
			ids << id
		}
	}
	mut found := map[int]P{}
	if ids.len == 0 {
		return found
	}
	key := primary_key[P]()
	for row in select_in[P](conn, key, ids)! {
		found[int_column[P](row, key) or { 0 }] = row
	}
	return found
}

// load_many returns the `C` records whose `fk` column holds the primary key of one
// of `parents`, keyed by that key, in one query. Parents with none have no entry.
// With `poly`, only the `C` records whose `poly.type_col` is `poly.type_val` are
// loaded.
pub fn load_many[P, C](conn orm.Connection, parents []P, fk string, poly Poly) !map[int][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[int][]C{}
	if ids.len == 0 {
		return grouped
	}
	mut rows := select_in[C](conn, fk, ids)!
	if poly.type_col != '' {
		rows = rows.filter(string_column[C](it, poly.type_col) or { '' } == poly.type_val)
	}
	for row in rows {
		grouped[int_column[C](row, fk) or { continue }] << row
	}
	return grouped
}

// keys_of returns the distinct primary keys of `rows`, in the order each first
// appears.
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

// primary_key returns the column of `T`'s `@[primary]` field, or `id`.
pub fn primary_key[T]() string {
	$for field in T.fields {
		if 'primary' in field.attrs {
			return column_name(field.name, field.attrs)
		}
	}
	return 'id'
}

// int_column returns the value of the `int` or `?int` field of `row` stored in
// `column`, or `none` when there is no such field or it is null.
pub fn int_column[T](row T, column string) ?int {
	$for field in T.fields {
		$if field.typ is int {
			if column_name(field.name, field.attrs) == column {
				return row.$(field.name)
			}
		} $else $if field.typ is ?int {
			if column_name(field.name, field.attrs) == column {
				return row.$(field.name)
			}
		}
	}
	return none
}

// string_column returns the value of the `string` field of `row` stored in
// `column`, or `none` when there is no such field.
pub fn string_column[T](row T, column string) ?string {
	$for field in T.fields {
		$if field.typ is string {
			if column_name(field.name, field.attrs) == column {
				return row.$(field.name)
			}
		}
	}
	return none
}
