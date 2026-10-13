module load

import orm

// select_in returns the `T` records whose `column` is one of `ids`, keys in their
// string form, narrowed and ordered by `opts`: one query, or two through a
// vgraph driver when the ORM can't run it. It calls `orm.Connection.select`
// directly: `orm.new_query`, which could do this, leaves the standard library
// after 2027-08-17 (PLAN.md, Q17). Fields may be `int`, `i64`, `f64`, `bool`,
// `string` or `time.Time`, or options of those.
pub fn select_in[T](conn orm.Connection, column string, ids []string, opts Options) ![]T {
	mut conds := [in_keys(column, ids, key_type[T](column)!)]
	if opts.type_col != '' {
		conds << eq(opts.type_col, opts.type_val)
	}
	if opts.soft_del != '' {
		conds << is_null(opts.soft_del)
	}
	conds << opts.query.conds
	return select_rows[T](conn, table_name[T](), conds, opts.query, false)
}

// select_rows returns the `T` records of `table` that match `conds`, ordered,
// and limited when `limit` is set, as `q` says: through the ORM when it can run
// it, else keys first through a vgraph driver, then the rows by key.
fn select_rows[T](conn orm.Connection, table string, conds []Cond, q Query, limit bool) ![]T {
	key := primary_key[T]()
	p := plan(conn, table, key, key_type[T](key)!, conds, q, limit)!
	if p.none {
		return []T{}
	}
	if !p.keyed {
		rows, _ := run_select[T](conn, table, orm_where(p.root), q, limit, '')!
		return rows
	}
	if p.keys.len == 0 {
		return []T{}
	}
	rows, keys := run_select[T](conn, table, orm_where(in_keys(key, p.keys, p.kind)), Query{
		columns: q.columns
	}, false, key)!
	return in_order(rows, keys, p.keys)
}

// in_order returns `rows`, whose keys are `keys`, in the order of `order`.
fn in_order[T](rows []T, keys []string, order []string) []T {
	mut at := map[string]int{}
	for i, key in keys {
		at[key] = i
	}
	mut sorted := []T{cap: rows.len}
	for key in order {
		if i := at[key] {
			sorted << rows[i]
		}
	}
	return sorted
}

// select_into returns the rows of `table` that match `q`, read into `T` by
// column name: the app's struct for part of a table. With `q.distinct`, each
// distinct row once.
pub fn select_into[T](conn orm.Connection, table string, key string, kind KeyType, q Query) ![]T {
	p := plan(conn, table, key, kind, q.conds, q, true)!
	if p.none {
		return []T{}
	}
	if !p.keyed {
		rows, _ := run_select[T](conn, table, orm_where(p.root), q, true, '')!
		return rows
	}
	if p.keys.len == 0 {
		return []T{}
	}
	rows, keys := run_select[T](conn, table, orm_where(in_keys(key, p.keys, kind)), Query{},
		false, key)!
	sorted := in_order(rows, keys, p.keys)
	if !q.distinct {
		return sorted
	}
	mut seen := map[string]bool{}
	mut once := []T{}
	for row in sorted {
		text := '${row}'
		if text !in seen {
			seen[text] = true
			once << row
		}
	}
	return once
}

// run_select runs one select of `T`'s columns (only those of `q.columns`, when
// it names some) of `table` with `where`, ordered by `q`, and limited when
// `limit` is set. With `extra`, it also reads that column, and returns its
// values, as strings.
fn run_select[T](conn orm.Connection, table string, where orm.QueryData, q Query, limit bool, extra string) !([]T, []string) {
	mut fields, mut types := select_columns[T](q.columns)!
	if extra != '' {
		fields << extra
		types << orm.type_string
	}
	mut data := orm.QueryData{}
	has_offset := limit && q.offset > 0
	// SQLite needs a LIMIT before an OFFSET: no limit is the largest one
	has_limit := limit && (q.limit > 0 || has_offset)
	if has_limit {
		data.data << if q.limit > 0 { orm.Primitive(i64(q.limit)) } else { orm.Primitive(max_i64) }
		data.types << orm.type_idx['i64']
	}
	if has_offset {
		data.data << orm.Primitive(i64(q.offset))
		data.types << orm.type_idx['i64']
	}
	orders := q.all_orders()
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
		has_distinct: q.distinct
		primary:      if fields.len > 0 { fields[0] } else { 'id' }
		fields:       fields
		select_exprs: fields
		types:        types
	}
	mut c := conn
	rows := c.select(config, data, where)!
	mut result := []T{cap: rows.len}
	mut extras := []string{}
	for row in rows {
		result << map_row[T](row, q.columns)!
		if extra != '' {
			extras << cell_text(row[row.len - 1])
		}
	}
	return result, extras
}

// cell_text returns a selected cell as a string.
fn cell_text(cell orm.Primitive) string {
	return match cell {
		string { cell }
		int { cell.str() }
		i64 { cell.str() }
		f64 { cell.str() }
		bool {
			if cell { 'true' } else { 'false' }
		}
		else { '' }
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
