module vgraph

import context
import load
import orm
import time

// Writes. The generated builders collect a `MutationData` and run it here. A
// write runs in one transaction when the connection can run one
// (`Client.begin`); inside a transaction already, it joins it. Defaults apply
// first, then the hooks (`hooks_of`), outermost first, then, innermost, the
// checks and the SQL.

type Row = map[string]orm.Primitive

// create inserts the row `m` describes, with its edges, and returns its key in
// its string form, or '' when the row conflicted and `m` says `do_nothing`.
pub fn (c Client) create(m MutationData) !string {
	return c.create_bulk([m])![0]
}

// create_bulk inserts the rows `ms` describe, all of one table, with their
// edges, in one transaction, and returns their keys in order, '' for a row
// left out by `do_nothing`. Hooks run once per row. With a PostgreSQL driver
// and no hooks, rows that set the same columns go in one statement.
pub fn (c Client) create_bulk(ms []MutationData) ![]string {
	if ms.len == 0 {
		return []string{}
	}
	t := c.schema.table(ms[0].table)!
	if t.view {
		return error('`${t.name}` is a view: it has no writes')
	}
	for m in ms {
		if m.table != t.name {
			return error('create_bulk: `${m.table}` and `${t.name}` rows are mixed')
		}
	}
	tc := c.atomic()!
	keys := tc.create_all(t, ms) or {
		tc.rollback() or {}
		return err
	}
	tc.commit()!
	return keys
}

fn (c Client) create_all(t Table, ms []MutationData) ![]string {
	options := c.schema.options(t.name)
	hooks := c.hooks_of(t.name)
	if hooks.len == 0 {
		mut rows := []Row{cap: ms.len}
		for m in ms {
			mut data := m.clone()
			data.op = .create
			apply_defaults(t, options, mut data)
			row := prepare_create(t, options, data)!
			c.check_polymorphic(t, [], row)!
			c.free_partners(t, '', row)!
			rows << row
		}
		keys := c.insert_rows(t, rows, ms[0])!
		for i, m in ms {
			if keys[i] != '' {
				c.write_edges(t, keys[i], m)!
				c.write_bidi(t, keys[i], rows[i])!
			}
		}
		return keys
	}
	mut keys := []string{cap: ms.len}
	for m in ms {
		data := c.run(t, hooks, m, .create)!
		keys << data.row_key
	}
	return keys
}

// update_one updates the row whose key is `m.row_key`, with its edges, and
// reports whether there was one.
pub fn (c Client) update_one(m MutationData) !bool {
	return c.mutate(m, .update_one)!.affected > 0
}

// update updates the rows that match `m.conds`, with their edges, and returns
// how many there were. It reads their keys first, in the same transaction.
pub fn (c Client) update(m MutationData) !int {
	return c.mutate(m, .update)!.affected
}

// delete_one deletes the row whose key is `m.row_key`, and reports whether
// there was one.
pub fn (c Client) delete_one(m MutationData) !bool {
	return c.mutate(m, .delete_one)!.affected > 0
}

// delete deletes the rows that match `m.conds`, and returns how many there
// were. The join table rows of the table's many_to_many edges go with them;
// rows of other tables that hold their keys stay.
pub fn (c Client) delete(m MutationData) !int {
	return c.mutate(m, .delete)!.affected
}

// mutate runs `m` as `op` in a transaction, and returns it as the write left
// it.
fn (c Client) mutate(m MutationData, op Op) !&MutationData {
	t := c.schema.table(m.table)!
	if t.view {
		return error('`${t.name}` is a view: it has no writes')
	}
	tc := c.atomic()!
	data := tc.run(t, tc.hooks_of(t.name), m, op) or {
		tc.rollback() or {}
		return err
	}
	tc.commit()!
	return data
}

// run applies the defaults of `m`, then runs it as `op` through `hooks`, and
// returns it as the write left it.
fn (c Client) run(t Table, hooks []Hook, m MutationData, op Op) !&MutationData {
	mut data := &MutationData{
		...m.clone()
		op:     op
		client: c
	}
	apply_defaults(t, c.schema.options(t.name), mut data)
	// a `full` model's hooks each have a span, whose context reaches the write
	full := c.full_spans(t.name)
	mut chain := Mutate(fn [c, t, mut data, full] (ctx context.Context, mut _ Mutation) ! {
		if full {
			c.with_span_ctx(ctx).write(t, mut data)!
		} else {
			c.write(t, mut data)!
		}
	})
	for i := hooks.len - 1; i >= 0; i-- {
		h := hooks[i]
		chain = if full {
			Hook{
				...h
				run: c.traced_run(t.name, h)
			}.wrap(chain)
		} else {
			h.wrap(chain)
		}
	}
	mut iface := Mutation(data)
	chain(c.ctx, mut iface)!
	return data
}

// write runs `m`, the innermost step of its hooks: the checks, then the SQL.
fn (c Client) write(t Table, mut m MutationData) ! {
	options := c.schema.options(t.name)
	match m.op {
		.create {
			row := prepare_create(t, options, m)!
			c.check_polymorphic(t, [], row)!
			c.free_partners(t, '', row)!
			keys := c.insert_rows(t, [row], m)!
			m.row_key = keys[0]
			if m.row_key != '' {
				c.write_edges(t, m.row_key, m)!
				c.write_bidi(t, m.row_key, row)!
				m.affected = 1
			}
		}
		.update_one, .update {
			set := prepare_update(t, options, m)!
			m.affected = c.update_rows(t, set, m.target(t)!, m)!
		}
		.delete_one, .delete {
			m.affected = c.delete_rows(t, m.target(t)!)!
		}
	}
}

// target returns the conditions of the rows `m` reaches: its own, and its key
// for a `*_one` write.
fn (m MutationData) target(t Table) ![]load.Cond {
	mut conds := m.conds.clone()
	if m.op in [.update_one, .delete_one] {
		conds << load.in_keys(t.key, [m.row_key], key_type(t)!)
	}
	return conds
}

fn (c Client) update_rows(t Table, set Row, conds []load.Cond, m MutationData) !int {
	keys := c.select_keys(t, conds)!
	if keys.len == 0 {
		return 0
	}
	c.check_polymorphic(t, keys, set)!
	for key in keys {
		c.free_partners(t, key, set)!
	}
	if set.len > 0 {
		where := load.where_data([load.in_keys(t.key, keys, key_type(t)!)]) or { return 0 }
		mut conn := c.conn
		conn.update(orm.Table{ name: t.name }, query_data(set), where)!
	}
	for key in keys {
		if m.appends.len > 0 {
			c.append_json(t, key, m.appends)!
		}
		c.write_edges(t, key, m)!
		c.write_bidi(t, key, set)!
	}
	return keys.len
}

// append_json appends to the JSON arrays of the row with the key `key`, by
// column: it reads them (locking the row on PostgreSQL) and writes them back,
// in the write's transaction.
fn (c Client) append_json(t Table, key string, appends map[string]string) ! {
	typ := key_type(t)!
	if c.conn is Driver {
		d := c.conn as Driver
		if d.dialect() == .pg {
			load.select_keys_where(c.conn, t.name, t.key, typ, load.Query{
				conds: [load.in_keys(t.key, [key], typ)]
				lock:  load.Lock{
					mode: .update
				}
			}, false)!
		}
	}
	old := c.select_row(t, key)!
	mut set := Row{}
	for column, items in appends {
		current := old[column] or { orm.Primitive(orm.Null{}) }
		text := if current is string { current.trim_space() } else { '' }
		set[column] = json_concat(if text == '' { '[]' } else { text }, items)!
	}
	where := load.where_data([load.in_keys(t.key, [key], typ)]) or { return }
	mut conn := c.conn
	conn.update(orm.Table{ name: t.name }, query_data(set), where)!
}

// json_concat returns the JSON arrays `a` and `b` as one.
fn json_concat(a string, b string) !string {
	if !a.starts_with('[') || !a.ends_with(']') || !b.starts_with('[') || !b.ends_with(']') {
		return error('`append` needs JSON arrays, not `${a}` and `${b}`')
	}
	inner_a := a[1..a.len - 1].trim_space()
	inner_b := b[1..b.len - 1].trim_space()
	if inner_a == '' {
		return '[${inner_b}]'
	}
	if inner_b == '' {
		return '[${inner_a}]'
	}
	return '[${inner_a},${inner_b}]'
}

// free_partners clears, before the row with the key `key` ('' for a new one)
// is written with `values`, the column of each bidirectional many_to_one edge
// of the rows that hold the partner it gets, so its unique index holds.
fn (c Client) free_partners(t Table, key string, values Row) ! {
	typ := key_type(t)!
	for e in t.edges {
		if !e.bidi || e.kind != .many_to_one {
			continue
		}
		value := values[e.column] or { continue }
		partner := key_text(value)
		if partner == '' {
			continue
		}
		mut conds := [load.in_keys(e.column, [partner], typ)]
		if key != '' {
			conds << load.ne(t.key, key_value(key, typ))
		}
		c.set_null(t, e, conds)!
	}
}

// write_bidi keeps the pairs of the table's bidirectional many_to_one edges
// whose column `values` sets on the row with the key `key`: the rows that
// pointed at it, or at its new partner, stop, and the partner points back.
fn (c Client) write_bidi(t Table, key string, values Row) ! {
	typ := key_type(t)!
	for e in t.edges {
		if !e.bidi || e.kind != .many_to_one {
			continue
		}
		value := values[e.column] or { continue }
		partner := key_text(value)
		// whoever pointed at this row, but its partner
		mut conds := [load.in_keys(e.column, [key], typ)]
		if partner != '' {
			conds << load.ne(t.key, key_value(partner, typ))
		}
		c.set_null(t, e, conds)!
		if partner == '' {
			continue
		}
		// whoever pointed at the partner, but this row
		c.set_null(t, e, [load.in_keys(e.column, [partner], typ), load.ne(t.key, key_value(key, typ))])!
		mut set := Row{}
		set[e.column] = key_value(key, typ)
		where := load.where_data([load.in_keys(t.key, [partner], typ)]) or { continue }
		mut conn := c.conn
		conn.update(orm.Table{ name: t.name }, query_data(set), where)!
	}
}

fn (c Client) delete_rows(t Table, conds []load.Cond) !int {
	keys := c.select_keys(t, conds)!
	if keys.len == 0 {
		return 0
	}
	typ := key_type(t)!
	mut conn := c.conn
	for e in t.edges {
		if e.kind == .many_to_many {
			where := load.where_data([load.in_keys(e.column, keys, typ)]) or { continue }
			conn.delete(orm.Table{ name: e.through }, where)!
		}
	}
	where := load.where_data([load.in_keys(t.key, keys, typ)]) or { return 0 }
	conn.delete(orm.Table{ name: t.name }, where)!
	return keys.len
}

// apply_defaults sets the defaults of the columns `m` leaves unset: on a
// create, `default` and `default_now`; on an update, `update_default` and
// `update_now`. Hooks then see them.
fn apply_defaults(t Table, options map[string]Field, mut m MutationData) {
	for column in t.columns {
		if column.name in m.values || column.name in m.adds {
			continue
		}
		o := options[column.field] or { continue }
		match m.op {
			.create {
				if default := o.default {
					m.values[column.name] = default()
				} else if o.default_now {
					m.values[column.name] = now()
				}
			}
			.update_one, .update {
				if default := o.update_default {
					m.values[column.name] = default()
				} else if o.update_now {
					m.values[column.name] = now()
				}
			}
			else {}
		}
	}
}

// prepare_create returns the row `m` inserts. It reports a required column left
// unset, and runs every check.
fn prepare_create(t Table, options map[string]Field, m MutationData) !Row {
	if m.adds.len > 0 {
		return error("`${t.name}`: a create can't add to a column")
	}
	mut row := Row{}
	for name, value in m.values {
		t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		row[name] = value
	}
	for e in t.edges {
		if !e.required {
			continue
		}
		set := if value := row[e.column] { value !is orm.Null } else { false }
		if !set && (m.added[e.name] or { []string{} }).len == 0 {
			return ValidationError{
				table:   t.name
				field:   e.column
				message: 'the edge `${e.name}` is required'
			}
		}
	}
	for column in t.columns {
		if column.name !in row && !column.optional && !column.has_default {
			return ValidationError{
				table:   t.name
				field:   column.name
				message: 'is required'
			}
		}
	}
	check_values(t, options, row)!
	return row
}

// prepare_update returns the columns `m` sets on each row: its values and its
// additions. It reports a column that may not change, and runs every check.
fn prepare_update(t Table, options map[string]Field, m MutationData) !Row {
	for e in t.edges {
		if !e.immutable {
			continue
		}
		if (e.kind == .many_to_one && e.column in m.values) || e.name in m.added
			|| e.name in m.removed || e.name in m.cleared {
			return ValidationError{
				table:   t.name
				field:   e.column
				message: 'the edge `${e.name}` is immutable'
			}
		}
	}
	for column in m.appends.keys() {
		c := t.column(column) or { return error('`${t.name}` has no column `${column}`') }
		if c.json_type == '' || !c.json_type.starts_with('[]') {
			return error('`${t.name}.${column}` is not a JSON array: it has no `append`')
		}
	}
	mut set := Row{}
	for name, value in m.values {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if name == t.key {
			return ValidationError{
				table:   t.name
				field:   name
				message: "is the key, which can't change"
			}
		}
		if column.immutable {
			return ValidationError{
				table:   t.name
				field:   name
				message: 'is immutable'
			}
		}
		set[name] = value
	}
	check_values(t, options, set)!
	for name, delta in m.adds {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if name in set {
			return error('`${t.name}.${name}` is both set and added to')
		}
		if column.typ.trim_left('?') !in ['int', 'i64', 'f64'] || column.immutable
			|| name == t.key {
			return ValidationError{
				table:   t.name
				field:   name
				message: "can't be added to"
			}
		}
		set[name] = orm.InfixType{
			name:     name
			operator: .add
			right:    delta
		}
	}
	return set
}

// check_values checks each value of `row` against its column's type and
// options.
fn check_values(t Table, options map[string]Field, row Row) ! {
	for name, value in row {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if value is orm.Null {
			if !column.nullable {
				return ValidationError{
					table:   t.name
					field:   name
					message: "can't be null"
				}
			}
			continue
		}
		if !fits(column, value) {
			return ValidationError{
				table:   t.name
				field:   name
				message: 'is ${column.typ.trim_left('?')}, not ${value.type_name()}'
			}
		}
		if o := options[column.field] {
			o.check(t.name, name, value)!
		}
	}
}

// fits reports whether `value` has the type of `column`.
fn fits(column Column, value orm.Primitive) bool {
	return match column.typ.trim_left('?') {
		'i8' { value is i8 }
		'i16' { value is i16 }
		'int' { value is int }
		'i64' { value is i64 || value is int }
		'u8' { value is u8 }
		'u16' { value is u16 }
		'u32' { value is u32 }
		'u64' { value is u64 }
		'f32' { value is f32 }
		'f64' { value is f64 }
		'bool' { value is bool }
		'string' { value is string }
		'time.Time' { value is time.Time }
		'enum' { value is int || value is i64 }
		else { true }
	}
}

// insert_rows inserts `rows` and returns their keys. A driver returns them
// (`RETURNING`); without one, a key is the one the row sets, or `last_id()`.
fn (c Client) insert_rows(t Table, rows []Row, m MutationData) ![]string {
	if c.conn is Driver {
		mut d := c.conn as Driver
		// PostgreSQL returns a multi-row insert's rows in order; SQLite doesn't
		// promise to, and a row left out by `do_nothing` returns nothing
		if d.dialect() == .pg && m.on_conflict != .do_nothing && same_columns(rows) {
			return insert_returning(mut d, t, rows, m)
		}
		mut keys := []string{cap: rows.len}
		for row in rows {
			returned := insert_returning(mut d, t, [row], m)!
			keys << if returned.len > 0 { returned[0] } else { '' }
		}
		return keys
	}
	if m.conflict_columns.len > 0 {
		return error('`${t.name}`: an upsert needs a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg)')
	}
	key := t.column(t.key) or { return error('`${t.name}` has no key column `${t.key}`') }
	mut conn := c.conn
	mut keys := []string{cap: rows.len}
	for row in rows {
		if key.kind == .i64 && t.key !in row {
			// `last_id()` is 32 bits on SQLite, so a global id would come back wrong
			return error('`${t.name}`: reading back a new `i64` key needs a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg)')
		}
		conn.insert(orm.Table{ name: t.name }, query_data(row))!
		if value := row[t.key] {
			keys << key_text(value)
		} else if key.kind == .int {
			keys << conn.last_id().str()
		} else {
			return error('`${t.name}`: a create must set the key `${t.key}`')
		}
	}
	return keys
}

fn same_columns(rows []Row) bool {
	first := rows[0].keys()
	return first.len > 0 && rows.all(it.keys() == first)
}

// insert_returning inserts `rows`, which set the same columns, in one
// statement, and returns the keys it reports.
fn insert_returning(mut d Driver, t Table, rows []Row, m MutationData) ![]string {
	columns := rows[0].keys()
	mut p := load.Params{
		dialect: d.dialect()
	}
	mut sql := 'INSERT INTO ${load.quote(t.name)}'
	if columns.len == 0 {
		sql += ' DEFAULT VALUES'
	} else {
		mut tuples := []string{cap: rows.len}
		for row in rows {
			mut cells := []string{cap: columns.len}
			for name in columns {
				cells << p.add(row[name] or { orm.Null{} })!
			}
			tuples << '(${cells.join(', ')})'
		}
		sql += ' (${columns.map(load.quote(it)).join(', ')}) VALUES ${tuples.join(', ')}'
	}
	sql += conflict_clause(t, columns, m)!
	sql += ' RETURNING ${load.quote(t.key)}'
	result := d.exec_params(sql, p.values)!
	return result.map(if it.len > 0 { it[0] or { '' } } else { '' })
}

// conflict_clause returns the `ON CONFLICT` clause of an upsert, or ''.
fn conflict_clause(t Table, columns []string, m MutationData) !string {
	if m.conflict_columns.len == 0 {
		if m.on_conflict != .fail {
			return error('`${t.name}`: an upsert needs `on_conflict_columns`')
		}
		return ''
	}
	for name in m.conflict_columns {
		t.column(name) or { return error('`${t.name}` has no column `${name}`') }
	}
	target := ' ON CONFLICT (${m.conflict_columns.map(load.quote(it)).join(', ')})'
	keep := m.conflict_columns[0]
	ignore := '${target} DO UPDATE SET ${load.quote(keep)} = ${load.quote(t.name)}.${load.quote(keep)}'
	return match m.on_conflict {
		.fail {
			target
		}
		.do_nothing {
			'${target} DO NOTHING'
		}
		.ignore {
			ignore
		}
		.update_new_values {
			mut changed := []string{}
			for name in columns {
				column := t.column(name) or { continue }
				if name != t.key && name !in m.conflict_columns && !column.immutable {
					changed << '${load.quote(name)} = excluded.${load.quote(name)}'
				}
			}
			if changed.len == 0 { ignore } else { '${target} DO UPDATE SET ${changed.join(', ')}' }
		}
	}
}

// write_edges writes the edge changes of `m` for the row with the key `key`:
// clears, then removals, then additions.
fn (c Client) write_edges(t Table, key string, m MutationData) ! {
	mut conn := c.conn
	typ := key_type(t)!
	for name in m.cleared {
		e := c.schema.edge(t.name, name)!
		match e.kind {
			.one_to_many, .one_to_one {
				target := c.schema.table(e.to)!
				mut conds := [load.in_keys(e.column, [key], typ)]
				conds << type_conds(e)
				c.set_null(target, e, conds)!
			}
			.many_to_many {
				if where := load.where_data([load.in_keys(e.column, [key], typ)]) {
					conn.delete(orm.Table{ name: e.through }, where)!
				}
				if e.bidi {
					if where := load.where_data([load.in_keys(e.through_to, [key], typ)]) {
						conn.delete(orm.Table{ name: e.through }, where)!
					}
				}
			}
			.many_to_one {
				c.set_null(t, e, [load.in_keys(t.key, [key], typ)])!
			}
		}
	}
	for name, ids in m.removed {
		if ids.len == 0 {
			continue
		}
		e := c.schema.edge(t.name, name)!
		target := c.schema.table(e.to)!
		match e.kind {
			.one_to_many, .one_to_one {
				mut conds := [load.in_keys(target.key, ids, key_type(target)!),
					load.in_keys(e.column, [key], typ)]
				conds << type_conds(e)
				c.set_null(target, e, conds)!
			}
			.many_to_many {
				c.delete_pairs(e, key, ids, typ, key_type(target)!)!
			}
			.many_to_one {
				return error('`${t.name}.${name}` is many_to_one: clear it, or set another')
			}
		}
	}
	for name, ids in m.added {
		if ids.len == 0 {
			continue
		}
		e := c.schema.edge(t.name, name)!
		target := c.schema.table(e.to)!
		target_typ := key_type(target)!
		match e.kind {
			.one_to_many, .one_to_one {
				if e.kind == .one_to_one && ids.len > 1 {
					return error('`${t.name}.${name}` is one_to_one: set one target, not ${ids.len}')
				}
				mut set := Row{}
				set[e.column] = key_value(key, typ)
				if e.type_col != '' {
					set[e.type_col] = e.type_val
				}
				if where := load.where_data([load.in_keys(target.key, ids, target_typ)]) {
					conn.update(orm.Table{ name: target.name }, query_data(set), where)!
				}
			}
			.many_to_many {
				mut pairs := ids.map([key, it])
				if e.bidi {
					// a pair stored the other way already would be stored twice
					c.delete_pairs(e, key, ids, typ, target_typ)!
					pairs << ids.filter(it != key).map([it, key])
				}
				c.insert_pairs(e, pairs, typ, target_typ)!
			}
			.many_to_one {
				if ids.len != 1 {
					return error('`${t.name}.${name}` is many_to_one: set one target, not ${ids.len}')
				}
				mut set := Row{}
				set[e.column] = key_value(ids[0], target_typ)
				if e.type_col != '' {
					set[e.type_col] = e.type_val
					c.check_target(t, e.column, target, ids[0], e.type_val)!
				}
				where := load.where_data([load.in_keys(t.key, [key], typ)]) or { continue }
				conn.update(orm.Table{ name: t.name }, query_data(set), where)!
			}
		}
	}
}

// check_polymorphic checks each polymorphic column pair of `t` (`polymorphics`)
// that `values` sets: its key column must name a row of the table its type
// column names. On an update, `keys` are the rows written: a pair that
// `values` sets only half of takes the other half from each stored row.
fn (c Client) check_polymorphic(t Table, keys []string, values Row) ! {
	for p in c.schema.polymorphics() {
		if p.table != t.name || (p.column !in values && p.type_col !in values) {
			continue
		}
		if keys.len == 0 || (p.column in values && p.type_col in values) {
			c.check_pair(t, p, values)!
			continue
		}
		for key in keys {
			mut row := c.select_row(t, key)!
			for name, value in values {
				row[name] = value
			}
			c.check_pair(t, p, row)!
		}
	}
}

// check_pair checks the polymorphic column pair `p` of `row`: a null key
// names no row, and passes.
fn (c Client) check_pair(t Table, p Polymorphic, row Row) ! {
	value := row[p.column] or { orm.Primitive(orm.Null{}) }
	if value is orm.Null {
		return
	}
	type_value := row[p.type_col] or { orm.Primitive(orm.Null{}) }
	name := if type_value is string { type_value } else { '' }
	table := p.targets[name] or {
		mut known := p.targets.keys()
		known.sort()
		return ValidationError{
			table:   t.name
			field:   p.type_col
			message: if name == '' {
				'is required with `${p.column}`'
			} else {
				'is `${name}`, not one of ${known.map('`${it}`').join(', ')}'
			}
		}
	}
	c.check_target(t, p.column, c.schema.table(table)!, key_text(value), name)!
}

// check_target checks that `key`, which the column `column` of `t` is set to,
// names a row of `target`, whose type is `name`. It reads through `target`'s
// root query, so its privacy rules and interceptors apply: a soft-deleted row
// counts as missing.
fn (c Client) check_target(t Table, column string, target Table, key string, name string) ! {
	typ := key_type(target)!
	q := c.prepare_query(target.name, load.Query{
		conds: [load.in_keys(target.key, [key], typ)]
	})!
	if load.select_keys_where(c.conn, target.name, target.key, typ, q, false)!.len == 0 {
		return ValidationError{
			table:   t.name
			field:   column
			message: 'no `${name}` has the key `${key}`'
		}
	}
}

// delete_pairs deletes the join rows of the many_to_many edge `e` from `key`
// to each of `ids`, and back, for a bidirectional one.
fn (c Client) delete_pairs(e Edge, key string, ids []string, typ load.KeyType, target_typ load.KeyType) ! {
	mut conn := c.conn
	if where := load.where_data([load.in_keys(e.column, [key], typ),
		load.in_keys(e.through_to, ids, target_typ)])
	{
		conn.delete(orm.Table{ name: e.through }, where)!
	}
	if e.bidi {
		if where := load.where_data([load.in_keys(e.column, ids, target_typ),
			load.in_keys(e.through_to, [key], typ)])
		{
			conn.delete(orm.Table{ name: e.through }, where)!
		}
	}
}

// insert_pairs stores the join rows `pairs` (`[from, to]` keys) of the
// many_to_many edge `e`. The join table of an edge schema, a struct of its
// own, gets them through its own create, with its defaults and hooks.
fn (c Client) insert_pairs(e Edge, pairs [][]string, typ load.KeyType, target_typ load.KeyType) ! {
	if pairs.len == 0 {
		return
	}
	if join := c.schema.tables[e.through] {
		for pair in pairs {
			mut values := map[string]orm.Primitive{}
			values[e.column] = key_value(pair[0], typ)
			values[e.through_to] = key_value(pair[1], target_typ)
			c.create(MutationData{
				table:  join.name
				values: values
			}) or {
				if err is ValidationError && err.message == 'is required' {
					return error('`${join.name}.${err.field}` is required: create `${join.name}` rows through their own builder')
				}
				return err
			}
		}
		return
	}
	mut data := orm.QueryData{
		fields:     [e.column, e.through_to]
		batch_rows: pairs.len
	}
	for pair in pairs {
		data.data << key_value(pair[0], typ)
		data.data << key_value(pair[1], target_typ)
	}
	mut conn := c.conn
	conn.insert(orm.Table{ name: e.through }, data)!
}

// set_null sets the column of the edge `e`, which `table` holds, to null on
// the rows that match `conds`.
fn (c Client) set_null(table Table, e Edge, conds []load.Cond) ! {
	column := table.column(e.column) or {
		return error('`${table.name}` has no column `${e.column}`')
	}
	if !column.nullable {
		return error("`${table.name}.${e.column}` is not nullable, so `${e.name}` can't lose a target; delete it, or point it elsewhere")
	}
	mut set := Row{}
	set[e.column] = orm.Null{}
	where := load.where_data(conds) or { return }
	mut conn := c.conn
	conn.update(orm.Table{ name: table.name }, query_data(set), where)!
}

// type_conds returns the condition on a polymorphic edge's type, if it has
// one.
fn type_conds(e Edge) []load.Cond {
	return if e.type_col != '' { [load.eq(e.type_col, e.type_val)] } else { [] }
}

// select_keys returns the keys of the rows of `t` that match `conds`, as
// strings, in one query.
fn (c Client) select_keys(t Table, conds []load.Cond) ![]string {
	return load.select_keys_where(c.conn, t.name, t.key, key_type(t)!, load.Query{
		conds: conds
	}, false)
}

// query_data returns `row` as the ORM's data for an insert or update.
fn query_data(row Row) orm.QueryData {
	mut data := orm.QueryData{}
	for name, value in row {
		data.fields << name
		data.data << value
		data.types << load.value_type(value)
	}
	return data
}

// key_type returns the type of `t`'s key.
fn key_type(t Table) !load.KeyType {
	column := t.column(t.key) or { return error('`${t.name}` has no key column `${t.key}`') }
	return match column.kind {
		.int { load.KeyType.int }
		.i64 { load.KeyType.i64 }
		.string { load.KeyType.string }
		.other {
			error('the key `${t.name}.${t.key}` is ${column.typ}; keys are int, i64 or string')
		}
	}
}

// key_value returns the key `key`, in its string form, as a value of `typ`.
fn key_value(key string, typ load.KeyType) orm.Primitive {
	return match typ {
		.int { orm.Primitive(key.int()) }
		.i64 { orm.Primitive(key.i64()) }
		.string { orm.Primitive(key) }
	}
}

// key_text returns a key's string form.
fn key_text(value orm.Primitive) string {
	return match value {
		int { value.str() }
		i64 { value.str() }
		string { value }
		else { '' }
	}
}

// select_row returns the stored values of the row of `t` with the key `key`,
// by column, in one query.
fn (c Client) select_row(t Table, key string) !Row {
	mut names := []string{}
	mut types := []int{}
	for column in t.columns {
		base := column.typ.trim_left('?')
		typ := match base {
			'i8', 'i16', 'int', 'i64', 'u8', 'u16', 'f32', 'f64', 'bool' {
				orm.type_idx[base]
			}
			'u32', 'u64' {
				// db.pg decodes these cells wrongly
				orm.type_idx['i64']
			}
			'enum' {
				orm.type_idx['int']
			}
			'string' {
				orm.type_string
			}
			'time.Time' {
				orm.time_
			}
			else {
				continue
			}
		}
		names << column.name
		types << typ
	}
	where := load.where_data([load.in_keys(t.key, [key], key_type(t)!)]) or {
		return error('`${t.name}`: no row has the key `${key}`')
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: t.name
		}
		has_where:    true
		primary:      t.key
		fields:       names
		select_exprs: names
		types:        types
	}
	mut conn := c.conn
	rows := conn.select(config, orm.QueryData{}, where)!
	if rows.len == 0 {
		return error('`${t.name}`: no row has the key `${key}`')
	}
	mut row := Row{}
	for i, name in names {
		row[name] = rows[0][i]
	}
	return row
}
