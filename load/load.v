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
	// query adds conditions and an order to the loaded rows. Its limit is
	// ignored: it would apply to all parents together, not to each.
	query Query
}

// load_one returns the `P` records that `children` refer to through their `fk`
// column, keyed by the `P` primary key's string form (`'3'`, or a UUID), in one
// query (one per `max_keys` keys). Children whose `fk` is null, and repeated keys, are skipped, and there
// is no query when no key is left.
pub fn load_one[C, P](conn orm.Connection, children []C, fk string, opts Options) !map[string]P {
	mut ids := []string{}
	mut seen := map[string]bool{}
	for child in children {
		if opts.type_col != '' {
			type_val := string_column[C](child, opts.type_col) or {
				return error('`${opts.type_col}` is not a string column')
			}
			if type_val != opts.type_val {
				continue
			}
		}
		id := key_column[C](child, fk) or { continue }
		if id !in seen {
			seen[id] = true
			ids << id
		}
	}
	mut found := map[string]P{}
	if ids.len == 0 {
		return found
	}
	key := primary_key[P]()
	// unordered, so a long list of keys is split: the rows go in a map
	query := Query{
		...opts.query
		order:  ''
		desc:   false
		orders: []Order{}
	}
	for row in select_in[P](conn, key, ids, soft_del: opts.soft_del, query: query)! {
		found[key_column[P](row, key) or { '' }] = row
	}
	return found
}

// load_many returns the `C` records whose `fk` column holds the primary key of one
// of `parents`, keyed by that key's string form, in one query (one per
// `max_keys` parents). Parents with none have no entry.
pub fn load_many[P, C](conn orm.Connection, parents []P, fk string, opts Options) !map[string][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[string][]C{}
	if ids.len == 0 {
		return grouped
	}
	for row in select_in[C](conn, fk, ids, opts)! {
		grouped[key_column[C](row, fk) or { continue }] << row
	}
	return grouped
}

// load_through returns the `C` records linked to each of `parents` through the
// join table `through`, whose `from_col` holds a parent's key and `to_col` a `C`
// key, keyed by the parent key's string form, in two queries: the join table,
// then `C` (more past `max_keys` parents or targets).
pub fn load_through[P, C](conn orm.Connection, parents []P, through string, from_col string, to_col string, opts Options) !map[string][]C {
	ids := keys_of[P](parents)!
	mut grouped := map[string][]C{}
	if ids.len == 0 {
		return grouped
	}
	key := primary_key[C]()
	pairs := link_pairs(conn, through, from_col, to_col, ids, key_type[P](primary_key[P]())!,
		key_type[C](key)!)!
	targets := unique(pairs.map(it[1]))
	if targets.len == 0 {
		return grouped
	}
	// each parent's rows in the order of the query: one select per group of
	// parents, so each parent's order comes from one statement
	for group in parent_groups(pairs) {
		mut parents_of := map[string][]string{}
		for pair in group {
			parents_of[pair[1]] << pair[0]
		}
		for row in select_in[C](conn, key, unique(group.map(it[1])), opts)! {
			for parent in parents_of[key_column[C](row, key) or { '' }] or { [] } {
				grouped[parent] << row
			}
		}
	}
	return grouped
}

// unique returns `ids` without repeats, in the order each first appears.
pub fn unique(ids []string) []string {
	mut seen := map[string]bool{}
	mut out := []string{cap: ids.len}
	for id in ids {
		if id !in seen {
			seen[id] = true
			out << id
		}
	}
	return out
}

// keys_of returns the distinct primary keys of `rows`, as strings, in the order
// each first appears.
pub fn keys_of[T](rows []T) ![]string {
	key := primary_key[T]()
	mut seen := map[string]bool{}
	mut ids := []string{cap: rows.len}
	for row in rows {
		id := key_column[T](row, key) or {
			return error('`${key}` is not an int, i64 or string column')
		}
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
