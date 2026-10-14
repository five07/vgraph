module load

import orm
import time

// Plan is how a query runs: through the ORM with `root`, or, `keyed`, by the
// `keys` a driver selected; `none` when it matches no row.
struct Plan {
	root  Cond
	keyed bool
	keys  []string
	kind  KeyType
	none  bool
}

// orm_orders reports whether the ORM can order as `q` says: by one column at
// most, with the database's nulls.
fn orm_orders(q Query) bool {
	orders := q.all_orders()
	return orders.len == 0
		|| (orders.len == 1 && orders[0].expr == '' && orders[0].nulls == .default)
}

// plan decides how the select of `table` with `conds`, ordered, limited when
// `limit` is set, and locked as `q` says, runs. Through the ORM when it can;
// else, with a driver, its keys first; else its subqueries first, and an error
// when the ORM still can't run it.
fn plan(conn orm.Connection, table string, key string, kind KeyType, conds []Cond, q Query, limit bool) !Plan {
	mut root := normalize(and(...conds), false)
	if root.junction == .false {
		return Plan{
			none: true
		}
	}
	if orm_ready(root) && orm_orders(q) && q.lock.mode == .off {
		return Plan{
			root: root
			kind: kind
		}
	}
	if conn is Raw {
		mut r := conn as Raw
		return Plan{
			root:  root
			keyed: true
			keys:  run_keys(mut r, table, key, root, q, limit)!
			kind:  kind
		}
	}
	root = normalize(downgrade(conn, resolve(conn, root)!)!, false)
	if root.junction == .false {
		return Plan{
			none: true
		}
	}
	if !orm_ready(root) || !orm_orders(q) || q.lock.mode != .off {
		return error(needs_driver)
	}
	return Plan{
		root: root
		kind: kind
	}
}

// downgrade returns `c` as the ORM can run it without a driver, where it can:
// an escaped pattern whose value had no `%`, `_` or `\` needs no escape, and on
// PostgreSQL a folded comparison is an ILIKE.
fn downgrade(conn orm.Connection, c Cond) !Cond {
	match c.junction {
		.and, .or, .not {
			mut children := []Cond{cap: c.children.len}
			for child in c.children {
				children << downgrade(conn, child)!
			}
			return Cond{
				...c
				children: children
			}
		}
		.leaf {
			mut next := c
			if c.escape {
				pattern := c.value as string
				if pattern.contains('\\') {
					return error('`${c.column}`: a value with `%`, `_` or `\\` needs a vgraph driver, which matches it as itself')
				}
				next = Cond{
					...next
					escape: false
				}
			}
			if c.fold {
				if !is_pg(conn) {
					return error('`${c.column}`: a case-insensitive match needs a vgraph driver on SQLite')
				}
				pattern := c.value as string
				if c.kind == .eq && (pattern.contains('%') || pattern.contains('_')) {
					return error('`${c.column}`: a value with `%` or `_` needs a vgraph driver to match it as itself')
				}
				next = Cond{
					...next
					kind: .orm_ilike
					fold: false
				}
			}
			return next
		}
		else {
			return c
		}
	}
}

// is_pg reports whether `conn` is one of `db.pg`'s connections.
fn is_pg(conn orm.Connection) bool {
	return conn.type_name().contains('pg.')
}

// keys_sql returns the select of the keys of `table` that match `root`, ordered,
// limited when `limit` is set, and locked, as `q` says.
fn keys_sql(table string, key string, root Cond, q Query, limit bool, mut p Params) !string {
	mut sql_text := 'SELECT ${quote('t0')}.${quote(key)} FROM ${quote(table)} AS ${quote('t0')}'
	if root.junction != .true {
		sql_text += ' WHERE ${render(root, mut p)!}'
	}
	orders := q.all_orders()
	if orders.len > 0 {
		mut items := []string{}
		for o in orders {
			mut item := if o.expr != '' { o.expr } else { '${quote('t0')}.${quote(o.column)}' }
			item += if o.desc { ' DESC' } else { ' ASC' }
			item += match o.nulls {
				.default { '' }
				.first { ' NULLS FIRST' }
				.last { ' NULLS LAST' }
			}
			items << item
		}
		sql_text += ' ORDER BY ${items.join(', ')}'
	}
	// numbers, not parameters: SQLite takes no text for a LIMIT
	if limit && (q.limit > 0 || q.offset > 0) {
		sql_text += ' LIMIT ${if q.limit > 0 { i64(q.limit) } else { max_i64 }}'
		if q.offset > 0 {
			sql_text += ' OFFSET ${q.offset}'
		}
	}
	if q.lock.mode != .off {
		if p.dialect != .pg {
			return error('SQLite has no row locks: `for_update` and `for_share` run on PostgreSQL')
		}
		sql_text += if q.lock.mode == .update { ' FOR UPDATE' } else { ' FOR SHARE' }
		if q.lock.no_wait {
			sql_text += ' NOWAIT'
		} else if q.lock.skip_locked {
			sql_text += ' SKIP LOCKED'
		}
	}
	return sql_text
}

// run_keys runs `keys_sql` through the driver `r`, and returns the keys.
fn run_keys(mut r Raw, table string, key string, root Cond, q Query, limit bool) ![]string {
	mut p := Params{
		dialect: r.dialect()
	}
	text := keys_sql(table, key, root, q, limit, mut p)!
	rows := r.exec_params(text, p.values)!
	return rows.map(if it.len > 0 { it[0] or { '' } } else { '' })
}

// select_keys_where returns the keys of the rows of `table` that match `q`, as
// strings, ordered, and limited when `limit` is set: one query, through the
// ORM or a driver.
pub fn select_keys_where(conn orm.Connection, table string, key string, kind KeyType, q Query, limit bool) ![]string {
	p := plan(conn, table, key, kind, q.conds, q, limit)!
	if p.none {
		return []string{}
	}
	if p.keyed {
		return p.keys
	}
	orders := q.all_orders()
	where := orm_where(p.root)
	mut data := orm.QueryData{}
	has_offset := limit && q.offset > 0
	has_limit := limit && (q.limit > 0 || has_offset)
	if has_limit {
		data.data << if q.limit > 0 { orm.Primitive(i64(q.limit)) } else { orm.Primitive(max_i64) }
		data.types << orm.type_idx['i64']
	}
	if has_offset {
		data.data << orm.Primitive(i64(q.offset))
		data.types << orm.type_idx['i64']
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table
		}
		has_where:    where.fields.len > 0
		has_order:    orders.len > 0
		order:        if orders.len > 0 { orders[0].column } else { '' }
		order_type:   if orders.len > 0 && orders[0].desc { .desc } else { .asc }
		has_limit:    has_limit
		has_offset:   has_offset
		primary:      key
		fields:       [key]
		select_exprs: [key]
		types:        [orm_type(kind)]
	}
	mut c := conn
	rows := c.select(config, data, where)!
	return rows.map(cell_key(it[0], key) or { '' })
}

// aggregate_where returns `kind` (count, sum, avg, min or max) of `column` over
// the rows of `table` that match `q`, in one query; 0 when no row has a value.
pub fn aggregate_where(conn orm.Connection, table string, key string, q Query, kind orm.AggregateKind, column string) !f64 {
	root := normalize(and(...q.conds), false)
	if root.junction == .false {
		return 0
	}
	if conn is Raw && !orm_ready(root) {
		mut r := conn as Raw
		mut p := Params{
			dialect: r.dialect()
		}
		expr := if kind == .count {
			'COUNT(*)'
		} else {
			'${kind.str().to_upper()}(${quote(column)})'
		}
		mut text := 'SELECT ${expr} FROM ${quote(table)} AS ${quote('t0')}'
		if root.junction != .true {
			text += ' WHERE ${render(root, mut p)!}'
		}
		rows := r.exec_params(text, p.values)!
		if rows.len == 0 || rows[0].len == 0 {
			return 0
		}
		return (rows[0][0] or { '0' }).f64()
	}
	mut where := root
	if !orm_ready(root) {
		where = normalize(downgrade(conn, resolve(conn, root)!)!, false)
		if where.junction == .false {
			return 0
		}
		if !orm_ready(where) {
			return error(needs_driver)
		}
	}
	data := orm_where(where)
	config := orm.SelectConfig{
		table:           orm.Table{
			name: table
		}
		aggregate_kind:  kind
		aggregate_field: column
		has_where:       data.fields.len > 0
		primary:         key
		types:           [if kind == .count { orm.type_idx['int'] } else { orm.type_idx['f64'] }]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, data)!
	if rows.len == 0 || rows[0].len == 0 {
		return 0
	}
	cell := rows[0][0]
	return match cell {
		int { f64(cell) }
		i64 { f64(cell) }
		f64 { cell }
		string { cell.f64() }
		else { 0 }
	}
}

// Aggregate is one value a group gets: `kind` of `column`, named `name` in the
// group's values.
pub struct Aggregate {
pub:
	kind   orm.AggregateKind
	column string
	name   string
}

// count returns the number of rows of a group, named `count`.
pub fn count() Aggregate {
	return Aggregate{
		kind: .count
		name: 'count'
	}
}

// sum returns the sum of `column` in a group, named `sum_<column>`.
pub fn sum(column string) Aggregate {
	return Aggregate{
		kind:   .sum
		column: column
		name:   'sum_${column}'
	}
}

// mean returns the mean of `column` in a group, named `mean_<column>`.
pub fn mean(column string) Aggregate {
	return Aggregate{
		kind:   .avg
		column: column
		name:   'mean_${column}'
	}
}

// min_of returns the least `column` of a group, named `min_<column>`.
pub fn min_of(column string) Aggregate {
	return Aggregate{
		kind:   .min
		column: column
		name:   'min_${column}'
	}
}

// max_of returns the greatest `column` of a group, named `max_<column>`.
pub fn max_of(column string) Aggregate {
	return Aggregate{
		kind:   .max
		column: column
		name:   'max_${column}'
	}
}

// GroupColumn is a column a query groups by, with its V type, such as `int`
// or `?string`.
pub struct GroupColumn {
pub:
	name string
	typ  string
}

// Group is one group of a `group_where`: the values of its columns, null as
// `orm.Null{}`, and its aggregates by name.
pub struct Group {
pub:
	key    map[string]orm.Primitive
	values map[string]f64
}

// group_where groups the rows of `table` that match `q` by `columns`, and
// returns each group, in the columns' order, with `aggregates`. It needs a
// driver: the ORM has no GROUP BY.
pub fn group_where(conn orm.Connection, table string, q Query, columns []GroupColumn, aggregates []Aggregate) ![]Group {
	if conn is Raw {
		mut r := conn as Raw
		root := normalize(and(...q.conds), false)
		if root.junction == .false {
			return []Group{}
		}
		mut p := Params{
			dialect: r.dialect()
		}
		mut selects := []string{}
		for c in columns {
			// whether it's null: SQLite returns a null cell as ''
			selects << quote(c.name)
			selects << 'CASE WHEN ${quote(c.name)} IS NULL THEN 1 ELSE 0 END'
		}
		for a in aggregates {
			selects << if a.kind == .count {
				'COUNT(*)'
			} else {
				'${a.kind.str().to_upper()}(${quote(a.column)})'
			}
		}
		names := columns.map(quote(it.name)).join(', ')
		mut text := 'SELECT ${selects.join(', ')} FROM ${quote(table)} AS ${quote('t0')}'
		if root.junction != .true {
			text += ' WHERE ${render(root, mut p)!}'
		}
		if columns.len > 0 {
			text += ' GROUP BY ${names} ORDER BY ${names}'
		}
		rows := r.exec_params(text, p.values)!
		mut groups := []Group{cap: rows.len}
		for row in rows {
			mut key := map[string]orm.Primitive{}
			for i, c in columns {
				null_cell := (row[2 * i + 1] or { '0' }) == '1'
				key[c.name] = if null_cell {
					orm.Primitive(orm.Null{})
				} else {
					parse_cell(row[2 * i] or { '' }, c.typ, r.dialect())!
				}
			}
			mut values := map[string]f64{}
			for i, a in aggregates {
				values[a.name] = (row[2 * columns.len + i] or { '0' }).f64()
			}
			groups << Group{
				key:    key
				values: values
			}
		}
		return groups
	}
	return error('`group_by` needs a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg): the ORM has no GROUP BY')
}

// parse_cell returns a cell a driver returned as text, as a value of the V type
// `typ`, stored the way V's ORM stores it on `dialect`.
fn parse_cell(text string, typ string, dialect orm.SQLDialect) !orm.Primitive {
	return match typ.trim_left('?') {
		'int', 'i8', 'i16', 'u8', 'u16', 'enum' {
			orm.Primitive(text.int())
		}
		'i64', 'u32', 'u64' {
			orm.Primitive(text.i64())
		}
		'f64', 'f32' {
			orm.Primitive(text.f64())
		}
		'bool' {
			orm.Primitive(text in ['1', 't', 'true'])
		}
		'string' {
			orm.Primitive(text)
		}
		'time.Time' {
			if dialect == .pg {
				orm.Primitive(time.parse(text.all_before('.').all_before('+'))!)
			} else {
				orm.Primitive(time.unix(text.i64()))
			}
		}
		else {
			error('vgraph cannot group by a ${typ}')
		}
	}
}

// scan_groups reads `groups` into `T` by name: each field named after a
// grouped column takes its value, and each named after an aggregate (`count`,
// `sum_views`) its number.
pub fn scan_groups[T](groups []Group) ![]T {
	mut out := []T{cap: groups.len}
	for g in groups {
		mut value := T{}
		$for field in T.fields {
			if v := g.values[field.name] {
				$if field.typ is int {
					value.$(field.name) = int(v)
				} $else $if field.typ is i64 {
					value.$(field.name) = i64(v)
				} $else $if field.typ is f64 {
					value.$(field.name) = v
				}
			} else if cell := g.key[field.name] {
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
					value.$(field.name) = cell as bool
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
				}
			}
		}
		out << value
	}
	return out
}
