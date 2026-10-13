// Package load loads the records at the other end of an edge for many records at
// once: one query per edge, never one per record. It works on column names;
// the `vgraph` module above it works on declared edges.
module load

import orm

// Options narrows what an edge loads.
@[params]
pub struct Options {
pub:
	// type_col and type_val make an edge polymorphic: only the rows whose
	// `type_col` is `type_val` are on it, such as comments whose `owner_type` is
	// `Article`. For `load_one` they filter the children, for `load_many` and
	// `load_through` the loaded rows.
	type_col string
	type_val string
	// soft_del names a column of the loaded rows that marks them deleted when it
	// is not null, such as `deleted_at`. Those rows are skipped.
	soft_del string
}

// load_one returns the `P` records that `children` refer to through their `fk`
// column, keyed by the `P` primary key, in one query. Children whose `fk` is
// null, and repeated keys, are skipped, and there is no query when no key is
// left.
pub fn load_one[C, P](conn orm.Connection, children []C, fk string, opts Options) !map[int]P {
	mut ids := []int{}
	mut seen := map[int]bool{}
	for child in children {
		if opts.type_col != '' {
			type_val := string_column[C](child, opts.type_col) or {
				return error('`${opts.type_col}` is not a string column')
			}
			if type_val != opts.type_val {
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
	for row in select_in[P](conn, key, ids, soft_del: opts.soft_del)! {
		found[int_column[P](row, key) or { 0 }] = row
	}
	return found
}

// load_many returns the `C` records whose `fk` column holds the primary key of one
// of `parents`, keyed by that key, in one query. Parents with none have no entry.
pub fn load_many[P, C](conn orm.Connection, parents []P, fk string, opts Options) !map[int][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[int][]C{}
	if ids.len == 0 {
		return grouped
	}
	for row in select_in[C](conn, fk, ids, opts)! {
		grouped[int_column[C](row, fk) or { continue }] << row
	}
	return grouped
}

// load_through returns the `C` records linked to each of `parents` through the
// join table `through`, whose `from_col` holds a parent's key and `to_col` a `C`
// key, keyed by the parent's key, in two queries: the join table, then `C`.
pub fn load_through[P, C](conn orm.Connection, parents []P, through string, from_col string, to_col string, opts Options) !map[int][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[int][]C{}
	if ids.len == 0 {
		return grouped
	}
	pairs := select_pairs(conn, through, from_col, to_col, ids)!
	mut targets := []int{}
	mut seen := map[int]bool{}
	for pair in pairs {
		if pair[1] !in seen {
			seen[pair[1]] = true
			targets << pair[1]
		}
	}
	if targets.len == 0 {
		return grouped
	}
	key := primary_key[C]()
	mut by_key := map[int]C{}
	for row in select_in[C](conn, key, targets, opts)! {
		by_key[int_column[C](row, key) or { 0 }] = row
	}
	for pair in pairs {
		if row := by_key[pair[1]] {
			grouped[pair[0]] << row
		}
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
