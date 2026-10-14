module load

import orm

// Keys can be `int`, `i64` or `string` (such as a UUID). Loads carry them as
// strings, their `str()` form, so one code path serves every key type, and turn
// them back into the column's type for each query.

// max_keys is the most keys one statement lists. A longer list is split, one
// statement per part: the databases cap a statement's parameters (65,535 on
// PostgreSQL, 32,766 on SQLite since 3.32), and this leaves room for the rest of
// its conditions.
pub const max_keys = 10_000

// chunks returns `keys` in parts of at most `max_keys`, in order: `[keys]` when
// it fits, even empty.
fn chunks(keys []string) [][]string {
	if keys.len <= max_keys {
		return [keys]
	}
	mut parts := [][]string{}
	for i := 0; i < keys.len; i += max_keys {
		end := if i + max_keys < keys.len { i + max_keys } else { keys.len }
		parts << keys[i..end]
	}
	return parts
}

// parent_groups returns the `[parent, target]` pairs `pairs` in groups of whole
// parents, each with at most `max_keys` distinct targets, or one parent's when
// it alone has more; `[pairs]` when they fit. An ordered load of the targets by
// key, one per group, then orders each parent's targets in one statement, which
// a split of the targets alone wouldn't.
pub fn parent_groups(pairs [][]string) [][][]string {
	if unique(pairs.map(it[1])).len <= max_keys {
		return [pairs]
	}
	mut parents := []string{}
	mut by_parent := map[string][][]string{}
	for pair in pairs {
		if pair[0] !in by_parent {
			parents << pair[0]
		}
		by_parent[pair[0]] << pair
	}
	mut groups := [][][]string{}
	mut group := [][]string{}
	mut targets := map[string]bool{}
	for parent in parents {
		list := by_parent[parent] or { continue }
		fresh := unique(list.map(it[1])).filter(it !in targets)
		if group.len > 0 && targets.len + fresh.len > max_keys {
			groups << group
			group = [][]string{}
			targets = map[string]bool{}
		}
		group << list
		for pair in list {
			targets[pair[1]] = true
		}
	}
	if group.len > 0 {
		groups << group
	}
	return groups
}

// KeyType is the type of a key column.
pub enum KeyType {
	int
	i64
	string
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
// whose `from_col` is one of `ids`, as strings, in one query per `max_keys` ids,
// or none without a query when `ids` is empty. `from` and `to` are the types of
// the two columns.
pub fn link_pairs(conn orm.Connection, table string, from_col string, to_col string, ids []string, from KeyType, to KeyType) ![][]string {
	if ids.len == 0 {
		return [][]string{}
	}
	mut pairs := [][]string{}
	for part in chunks(ids) {
		pairs << link_part(conn, table, from_col, to_col, part, from, to)!
	}
	return pairs
}

// link_part is `link_pairs` over one part of the ids.
fn link_part(conn orm.Connection, table string, from_col string, to_col string, ids []string, from KeyType, to KeyType) ![][]string {
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
	rows := c.select(config, orm.QueryData{}, orm_where(in_keys(from_col, ids, from)))!
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
