module load

import encoding.base64
import json2
import orm
import time

// Per-parent reads: an edge load whose query has a limit or an offset applies
// them to each parent's rows, not to all of them together. Through a vgraph
// driver the database cuts each parent's rows with a window function; without
// one, every row of the edge is read and cut here.

// paged reports whether `q` has a limit or an offset.
fn paged(q Query) bool {
	return q.limit > 0 || q.offset > 0
}

// window returns `ORDER BY …` of a window over `q`'s orders, then the key, for
// the table read as `t0`.
fn window_order(q Query, key string) string {
	mut items := []string{}
	for o in q.all_orders() {
		mut item := if o.expr != '' { o.expr } else { '${quote('t0')}.${quote(o.column)}' }
		item += if o.desc { ' DESC' } else { ' ASC' }
		item += match o.nulls {
			.default { '' }
			.first { ' NULLS FIRST' }
			.last { ' NULLS LAST' }
		}
		items << item
	}
	items << '${quote('t0')}.${quote(key)} ASC'
	return items.join(', ')
}

// window_bounds returns the condition on the row number `n` that `q`'s limit
// and offset keep.
fn window_bounds(q Query) string {
	n := quote('n')
	mut text := '${n} > ${q.offset}'
	if q.limit > 0 {
		text += ' AND ${n} <= ${i64(q.offset) + q.limit}'
	}
	return text
}

// select_each returns the `T` records whose `column` is one of `ids`, as
// `select_in` does, with `opts.query`'s limit and offset applied to the rows
// of each value of `column`, in the query's order. Through a vgraph driver,
// the database cuts them (two queries: the keys, then the rows); without one,
// every matching row is read and cut here.
pub fn select_each[T](conn orm.Connection, column string, ids []string, opts Options) ![]T {
	q := opts.query
	if !paged(q) {
		return select_in[T](conn, column, ids, opts)
	}
	if conn !is Raw {
		rows := select_in[T](conn, column, ids, opts)!
		mut seen := map[string]int{}
		mut out := []T{cap: rows.len}
		for row in rows {
			parent := key_column[T](row, column) or { continue }
			n := seen[parent] or { 0 }
			seen[parent] = n + 1
			if n >= q.offset && (q.limit == 0 || n < q.offset + q.limit) {
				out << row
			}
		}
		return out
	}
	mut r := conn as Raw
	table := table_name[T]()
	key := primary_key[T]()
	kind := key_type[T](key)!
	mut conds := [in_keys(column, ids, key_type[T](column)!)]
	if opts.type_col != '' {
		conds << eq(opts.type_col, opts.type_val)
	}
	if opts.soft_del != '' {
		conds << is_null(opts.soft_del)
	}
	conds << q.conds
	root := normalize(and(...conds), false)
	if root.junction == .false {
		return []T{}
	}
	mut p := Params{
		dialect: r.dialect()
	}
	mut inner := 'SELECT ${quote('t0')}.${quote(key)} AS ${quote('k')}, ${quote('t0')}.${quote(column)} AS ${quote('p')}, ROW_NUMBER() OVER (PARTITION BY ${quote('t0')}.${quote(column)} ORDER BY ${window_order(q, key)}) AS ${quote('n')} FROM ${quote(table)} AS ${quote('t0')}'
	if root.junction != .true {
		inner += ' WHERE ${render(root, mut p)!}'
	}
	text := 'SELECT ${quote('k')} FROM (${inner}) AS ${quote('w')} WHERE ${window_bounds(q)} ORDER BY ${quote('p')}, ${quote('n')}'
	keys := r.exec_params(text, p.values)!.map(if it.len > 0 { it[0] or { '' } } else { '' })
	if keys.len == 0 {
		return []T{}
	}
	rows, got := run_select[T](conn, table, orm_where(in_keys(key, keys, kind)), Query{
		columns: q.columns
	}, false, key)!
	return in_order(rows, got, keys)
}

// link_each returns the `[from_col, to_col]` pairs of the join table `through`
// whose `from_col` is one of `ids`, and whose `to_col` is a row of `target`
// (keyed by `target_key`) that matches `q`, in `q`'s order for each parent,
// with `q`'s limit and offset applied to each parent's pairs. Through a vgraph
// driver it is one query; without one, three: the pairs, the targets' keys in
// order, and none more.
pub fn link_each(conn orm.Connection, through string, from_col string, to_col string, ids []string, from KeyType, to KeyType, target string, target_key string, q Query) ![][]string {
	if ids.len == 0 {
		return [][]string{}
	}
	if conn !is Raw {
		pairs := link_pairs(conn, through, from_col, to_col, ids, from, to)!
		targets := unique(pairs.map(it[1]))
		if targets.len == 0 {
			return [][]string{}
		}
		mut conds := [in_keys(target_key, targets, to)]
		conds << q.conds
		order := select_keys_where(conn, target, target_key, to, Query{
			...q
			conds:  conds
			limit:  0
			offset: 0
		}, false)!
		mut at := map[string]int{}
		for i, k in order {
			at[k] = i
		}
		mut by_parent := map[string][]string{}
		mut parents := []string{}
		for pair in pairs {
			if pair[1] !in at {
				continue
			}
			if pair[0] !in by_parent {
				parents << pair[0]
			}
			by_parent[pair[0]] << pair[1]
		}
		mut out := [][]string{}
		for parent in parents {
			mut list := by_parent[parent]
			list.sort_with_compare(fn [at] (a &string, b &string) int {
				return (at[*a] or { 0 }) - (at[*b] or { 0 })
			})
			for i, t in list {
				if i >= q.offset && (q.limit == 0 || i < q.offset + q.limit) {
					out << [parent, t]
				}
			}
		}
		return out
	}
	mut r := conn as Raw
	root := normalize(and(...q.conds), false)
	if root.junction == .false {
		return [][]string{}
	}
	mut p := Params{
		dialect: r.dialect()
	}
	mut targets := 'SELECT * FROM ${quote(target)}'
	if root.junction != .true {
		targets += ' WHERE ${render(root, mut p)!}'
	}
	join := '${quote('j')}.${quote(from_col)}'
	parent_in := render(in_keys(from_col, ids, from), mut p)!
	inner := 'SELECT ${join} AS ${quote('p')}, ${quote('t0')}.${quote(target_key)} AS ${quote('k')}, ROW_NUMBER() OVER (PARTITION BY ${join} ORDER BY ${window_order(q, target_key)}) AS ${quote('n')} FROM ${quote(through)} AS ${quote('j')} JOIN (${targets}) AS ${quote('t0')} ON ${quote('t0')}.${quote(target_key)} = ${quote('j')}.${quote(to_col)} WHERE ${quote('j')}.${parent_in}'
	bounds := if paged(q) { window_bounds(q) } else { '1 = 1' }
	text := 'SELECT ${quote('p')}, ${quote('k')} FROM (${inner}) AS ${quote('w')} WHERE ${bounds} ORDER BY ${quote('p')}, ${quote('n')}'
	return r.exec_params(text, p.values)!.map([it[0] or { '' }, it[1] or { '' }])
}

// count_each returns how many rows of `table` match `q` for each value of
// `column` among `ids`, keyed by that value; values with none have no entry.
// Through a vgraph driver it is one GROUP BY; without one, the column of each
// matching row is read and counted here.
pub fn count_each(conn orm.Connection, table string, column string, ids []string, kind KeyType, q Query) !map[string]int {
	mut counts := map[string]int{}
	if ids.len == 0 {
		return counts
	}
	mut conds := [in_keys(column, ids, kind)]
	conds << q.conds
	root := normalize(and(...conds), false)
	if root.junction == .false {
		return counts
	}
	if conn is Raw {
		mut r := conn as Raw
		mut p := Params{
			dialect: r.dialect()
		}
		mut text := 'SELECT ${quote(column)}, COUNT(*) FROM ${quote(table)} AS ${quote('t0')}'
		if root.junction != .true {
			text += ' WHERE ${render(root, mut p)!}'
		}
		text += ' GROUP BY ${quote(column)}'
		for row in r.exec_params(text, p.values)! {
			counts[row[0] or { '' }] = (row[1] or { '0' }).int()
		}
		return counts
	}
	mut where := root
	if !orm_ready(root) {
		where = normalize(downgrade(conn, resolve(conn, root)!)!, false)
		if where.junction == .false {
			return counts
		}
		if !orm_ready(where) {
			return error(needs_driver)
		}
	}
	for value in select_values(conn, table, column, kind, where, false)! {
		counts[value]++
	}
	return counts
}

// count_through returns how many rows of `target` that match `q` each of `ids`
// is linked to through the join table `through`, keyed by the parent's key;
// parents with none have no entry. Through a vgraph driver it is one GROUP BY;
// without one, the pairs and the matching targets' keys are read, and counted
// here.
pub fn count_through(conn orm.Connection, through string, from_col string, to_col string, ids []string, from KeyType, to KeyType, target string, target_key string, q Query) !map[string]int {
	mut counts := map[string]int{}
	if ids.len == 0 {
		return counts
	}
	if conn is Raw {
		mut r := conn as Raw
		cond := normalize(and(in_keys(from_col, ids, from), in_sub(to_col, Sub{
			table:  target
			column: target_key
			kind:   to
			conds:  q.conds
		})), false)
		if cond.junction == .false {
			return counts
		}
		mut p := Params{
			dialect: r.dialect()
		}
		text := 'SELECT ${quote(from_col)}, COUNT(*) FROM ${quote(through)} WHERE ${render(cond, mut p)!} GROUP BY ${quote(from_col)}'
		for row in r.exec_params(text, p.values)! {
			counts[row[0] or { '' }] = (row[1] or { '0' }).int()
		}
		return counts
	}
	pairs := link_pairs(conn, through, from_col, to_col, ids, from, to)!
	targets := unique(pairs.map(it[1]))
	if targets.len == 0 {
		return counts
	}
	mut conds := [in_keys(target_key, targets, to)]
	conds << q.conds
	kept := select_keys_where(conn, target, target_key, to, Query{
		conds: conds
	}, false)!
	mut ok := map[string]bool{}
	for k in kept {
		ok[k] = true
	}
	for pair in pairs {
		if pair[1] in ok {
			counts[pair[0]]++
		}
	}
	return counts
}

// select_values returns `column` of each row of `table` that matches `where`,
// normalized and ready for the ORM, as strings: every row's, or each distinct
// value once.
fn select_values(conn orm.Connection, table string, column string, kind KeyType, where Cond, distinct bool) ![]string {
	data := orm_where(where)
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table
		}
		has_where:    data.fields.len > 0
		has_distinct: distinct
		primary:      column
		fields:       [column]
		select_exprs: [column]
		types:        [orm_type(kind)]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, data)!
	return rows.map(cell_key(it[0], column) or { '' })
}

// Keyset pagination: a cursor holds the values of a row's order columns, the
// key last, and the rows after it (or before it) are those that come later
// (or earlier) in that order. A null compares as the database orders it: as
// the largest value on PostgreSQL, the smallest on SQLite.

// nulls_largest reports whether `conn` orders nulls as larger than any value,
// as PostgreSQL does; SQLite orders them as smaller.
pub fn nulls_largest(conn orm.Connection) bool {
	if conn is Raw {
		r := conn as Raw
		return r.dialect() == .pg
	}
	return is_pg(conn)
}

// has_driver reports whether `conn` is a vgraph driver, which runs the SQL the
// ORM can't.
pub fn has_driver(conn orm.Connection) bool {
	return conn is Raw
}

// keyset returns the condition that a row comes after (`after`) or before the
// row whose order values are `values`, in the order `orders`, which must end
// with a unique column, such as the key. An order by an SQL expression becomes
// raw SQL, which needs a driver.
pub fn keyset(orders []Order, values []orm.Primitive, after bool, nulls_largest bool) !Cond {
	if orders.len != values.len {
		return error('invalid cursor')
	}
	mut any := []Cond{}
	for i, o in orders {
		mut all := []Cond{}
		for j in 0 .. i {
			all << same(orders[j], values[j])
		}
		// past the cursor in this column: greater ascending, less descending;
		// the last column, the key, is never null
		all << beyond(o, values[i], after != o.desc, nulls_largest && i < orders.len - 1,
			!nulls_largest && i < orders.len - 1)
		any << and(...all)
	}
	// not `or(...)`: inside this module it parses as the keyword
	return Cond{
		junction: .or
		children: any
	}
}

// same returns the condition that the order column `o` holds `value`.
fn same(o Order, value orm.Primitive) Cond {
	if o.expr != '' {
		if value is orm.Null {
			return raw('${o.expr} IS NULL')
		}
		return raw('${o.expr} = ?', value)
	}
	if value is orm.Null {
		return is_null(o.column)
	}
	return eq(o.column, value)
}

// beyond returns the condition that the order column `o` holds a value greater
// (`greater`) or less than `value`, with nulls the largest values
// (`nulls_largest`), the smallest (`nulls_smallest`), or, with neither, none.
fn beyond(o Order, value orm.Primitive, greater bool, nulls_largest bool, nulls_smallest bool) Cond {
	null_cond := if o.expr != '' { raw('${o.expr} IS NULL') } else { is_null(o.column) }
	not_null := if o.expr != '' { raw('${o.expr} IS NOT NULL') } else { is_not_null(o.column) }
	if value is orm.Null {
		// nothing is beyond the largest value, or below the smallest
		return if greater == nulls_largest {
			Cond{
				junction: .false
			}
		} else {
			not_null
		}
	}
	cmp := if o.expr != '' {
		raw('${o.expr} ${if greater { '>' } else { '<' }} ?', value)
	} else if greater {
		gt(o.column, value)
	} else {
		lt(o.column, value)
	}
	// past a value: the nulls too, when they are on that side
	return if (greater && nulls_largest) || (!greater && nulls_smallest) {
		Cond{
			junction: .or
			children: [cmp, null_cond]
		}
	} else {
		cmp
	}
}

// encode_cursor returns the cursor of a row with the order values `values`:
// base64 of a JSON list of their text, or null.
pub fn encode_cursor(values []orm.Primitive) string {
	mut items := []json2.Any{}
	for v in values {
		items << if v is orm.Null { json2.Any(json2.null) } else { json2.Any(value_text(v)) }
	}
	return base64.url_encode_str(json2.encode(items))
}

// decode_cursor returns the order values of a cursor, read as the V types
// `types` (such as `int`, `?string` or `time.Time`).
pub fn decode_cursor(cursor string, types []string) ![]orm.Primitive {
	text := base64.url_decode_str(cursor)
	items := json2.decode[[]json2.Any](text) or { return error('invalid cursor') }
	if items.len != types.len {
		return error('invalid cursor')
	}
	mut out := []orm.Primitive{cap: items.len}
	for i, item in items {
		if item is json2.Null {
			out << orm.Null{}
			continue
		}
		out << text_value((item as string), types[i]) or { return error('invalid cursor') }
	}
	return out
}

// value_text returns a value as text that `text_value` reads back.
fn value_text(v orm.Primitive) string {
	return match v {
		time.Time { v.format_rfc3339_micro() }
		bool { v.str() }
		string { v }
		else { cell_text_any(v) }
	}
}

fn cell_text_any(v orm.Primitive) string {
	return match v {
		i8, i16, int, i64, u8, u16, u32, u64 { v.str() }
		f32, f64 { v.str() }
		else { '' }
	}
}

// text_value reads `text` as a value of the V type `typ`.
fn text_value(text string, typ string) !orm.Primitive {
	return match typ.trim_left('?') {
		'i8', 'i16', 'int', 'u8', 'u16', 'enum' {
			if text.int().str() != text {
				return error('not an int')
			}
			orm.Primitive(text.int())
		}
		'i64', 'u32', 'u64' {
			if text.i64().str() != text {
				return error('not an i64')
			}
			orm.Primitive(text.i64())
		}
		'f32', 'f64' {
			orm.Primitive(text.f64())
		}
		'bool' {
			orm.Primitive(text == 'true')
		}
		'string' {
			orm.Primitive(text)
		}
		'time.Time' {
			orm.Primitive(time.parse_rfc3339(text)!)
		}
		else {
			error('vgraph cannot page by a ${typ}')
		}
	}
}

// expr_values returns, for each of `keys` (a row of `table`, keyed by `key`),
// the values of the order expressions of `orders`, read as their `typ`, keyed
// by the row's key: what a cursor needs of an order by an edge. The columns'
// own orders get null here. It needs a vgraph driver.
pub fn expr_values(conn orm.Connection, table string, key string, kind KeyType, keys []string, orders []Order) !map[string][]orm.Primitive {
	mut out := map[string][]orm.Primitive{}
	exprs := orders.filter(it.expr != '')
	if exprs.len == 0 || keys.len == 0 {
		return out
	}
	if conn !is Raw {
		return error(needs_driver)
	}
	mut r := conn as Raw
	mut p := Params{
		dialect: r.dialect()
	}
	mut selects := ['${quote('t0')}.${quote(key)}']
	for o in exprs {
		// whether it's null: SQLite returns a null cell as ''
		selects << o.expr
		selects << 'CASE WHEN ${o.expr} IS NULL THEN 1 ELSE 0 END'
	}
	text := 'SELECT ${selects.join(', ')} FROM ${quote(table)} AS ${quote('t0')} WHERE ${quote('t0')}.${render(in_keys(key, keys, kind), mut p)!}'
	for row in r.exec_params(text, p.values)! {
		mut values := []orm.Primitive{}
		mut i := 0
		for o in orders {
			if o.expr == '' {
				values << orm.Null{}
				continue
			}
			if (row[2 + 2 * i] or { '0' }) == '1' {
				values << orm.Null{}
			} else {
				values << parse_cell(row[1 + 2 * i] or { '' }, o.typ, r.dialect())!
			}
			i++
		}
		out[row[0] or { '' }] = values
	}
	return out
}
