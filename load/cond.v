module load

import orm
import time

// Junction is what a condition is: a comparison, or a combination of others.
pub enum Junction {
	leaf  // `column kind value`
	and   // every one of `children`
	or    // any of `children`
	not   // not `children[0]`
	true  // every row
	false // no row
	sub   // `column IN (SELECT …)`: `sub[0]`
	raw   // `raw`, with `args` for its `?`
}

// Sub is a subquery of one column: `SELECT column FROM table WHERE conds`.
// Its column holds keys, so `kind` is the key type the column holds.
pub struct Sub {
pub:
	table  string
	column string
	kind   KeyType
	conds  []Cond
}

// Cond is a condition of a query, such as `title = 'V'`, or a combination of
// them (`and`, `or`, `not`). A query's conditions are joined with AND.
pub struct Cond {
pub:
	column   string
	kind     orm.OperationKind
	value    orm.Primitive = orm.null_primitive
	junction Junction
	children []Cond
	// negate: NOT around a comparison that no operator negates (LIKE, the
	// folded ones, a subquery, raw SQL)
	negate bool
	// escape: a LIKE pattern whose `%`, `_` and `\` are escaped with `\`
	escape bool
	// fold: compares `LOWER(column)` with `LOWER(value)`
	fold bool
	raw  string
	args []orm.Primitive
	sub  []Sub
}

// and returns the condition that every one of `conds` holds.
pub fn and(conds ...Cond) Cond {
	return Cond{
		junction: .and
		children: conds
	}
}

// or returns the condition that any of `conds` holds.
pub fn or(conds ...Cond) Cond {
	return Cond{
		junction: .or
		children: conds
	}
}

// not returns the condition that `cond` doesn't hold.
pub fn not(cond Cond) Cond {
	return Cond{
		junction: .not
		children: [cond]
	}
}

// escape_like returns `value` with `\`, `%` and `_` escaped with `\`, for a
// LIKE pattern with `ESCAPE '\'`.
pub fn escape_like(value string) string {
	return value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
}

// contains returns the condition that `column` contains `value`; `%` and `_`
// in it are themselves.
pub fn contains(column string, value string) Cond {
	return Cond{
		column: column
		kind:   .orm_like
		value:  '%${escape_like(value)}%'
		escape: true
	}
}

// has_prefix returns the condition that `column` starts with `value`.
pub fn has_prefix(column string, value string) Cond {
	return Cond{
		column: column
		kind:   .orm_like
		value:  '${escape_like(value)}%'
		escape: true
	}
}

// has_suffix returns the condition that `column` ends with `value`.
pub fn has_suffix(column string, value string) Cond {
	return Cond{
		column: column
		kind:   .orm_like
		value:  '%${escape_like(value)}'
		escape: true
	}
}

// equal_fold returns the condition that `column` equals `value`, ignoring
// case (ASCII on SQLite).
pub fn equal_fold(column string, value string) Cond {
	return Cond{
		column: column
		kind:   .eq
		value:  value
		fold:   true
	}
}

// contains_fold returns the condition that `column` contains `value`,
// ignoring case.
pub fn contains_fold(column string, value string) Cond {
	return Cond{
		column: column
		kind:   .orm_like
		value:  '%${escape_like(value)}%'
		escape: true
		fold:   true
	}
}

// raw returns a condition in SQL, with `?` for each of `args`, which are
// passed as parameters. It needs a vgraph driver.
pub fn raw(sql_text string, args ...orm.Primitive) Cond {
	return Cond{
		junction: .raw
		raw:      sql_text
		args:     args
	}
}

// in_sub returns the condition `column IN (SELECT sub.column FROM sub.table
// WHERE sub.conds)`. With a driver it is one subquery; without one, the
// subquery runs first.
pub fn in_sub(column string, sub Sub) Cond {
	return Cond{
		junction: .sub
		column:   column
		sub:      [sub]
	}
}

// normalize returns `c` with its negations pushed down to its comparisons, and
// its constants folded: an `IN ()` is false, a `NOT IN ()` true, and so on. The
// result is `.true`, `.false`, or has neither.
fn normalize(c Cond, negated bool) Cond {
	match c.junction {
		.true {
			return Cond{
				junction: if negated { .false } else { .true }
			}
		}
		.false {
			return Cond{
				junction: if negated { .true } else { .false }
			}
		}
		.not {
			return normalize(c.children[0], !negated)
		}
		.and, .or {
			// NOT (a AND b) is NOT a OR NOT b
			is_and := (c.junction == .and) != negated
			mut kept := []Cond{}
			for child in c.children {
				n := normalize(child, negated)
				if n.junction == .true {
					if is_and {
						continue
					}
					return n
				}
				if n.junction == .false {
					if is_and {
						return n
					}
					continue
				}
				// flatten a group of the same kind
				if (n.junction == .and && is_and) || (n.junction == .or && !is_and) {
					kept << n.children
				} else {
					kept << n
				}
			}
			if kept.len == 0 {
				return Cond{
					junction: if is_and { .true } else { .false }
				}
			}
			if kept.len == 1 {
				return kept[0]
			}
			return Cond{
				junction: if is_and { .and } else { .or }
				children: kept
			}
		}
		.sub {
			return Cond{
				...c
				negate: c.negate != negated
			}
		}
		.raw {
			return Cond{
				...c
				negate: c.negate != negated
			}
		}
		.leaf {
			if c.kind in [.in, .not_in] && is_empty_list(c.value) {
				// IN () matches no row, NOT IN () every row
				empty_true := (c.kind == .not_in) != (negated != c.negate)
				return Cond{
					junction: if empty_true { .true } else { .false }
				}
			}
			if !negated {
				return c
			}
			if c.negate || c.fold || c.kind in [.orm_like, .orm_ilike] {
				return Cond{
					...c
					negate: !c.negate
				}
			}
			return Cond{
				...c
				kind: match c.kind {
					.eq { orm.OperationKind.neq }
					.neq { .eq }
					.lt { .ge }
					.ge { .lt }
					.le { .gt }
					.gt { .le }
					.in { .not_in }
					.not_in { .in }
					.is_null { .is_not_null }
					.is_not_null { .is_null }
					else { c.kind }
				}
			}
		}
	}
}

// orm_ready reports whether the ORM can run `c`, normalized: comparisons the
// ORM has, joined with AND and OR.
fn orm_ready(c Cond) bool {
	return match c.junction {
		.and, .or { c.children.all(orm_ready(it)) }
		.leaf { !c.negate && !c.fold && !c.escape }
		.true { true }
		else { false }
	}
}

// has_subs reports whether `c` has a subquery.
fn has_subs(c Cond) bool {
	return match c.junction {
		.sub { true }
		.and, .or, .not { c.children.any(has_subs(it)) }
		else { false }
	}
}

// orm_where returns `c`, normalized and ready for the ORM, as its where data:
// the comparisons in order, AND or OR between each two, and parentheses around
// each nested group.
fn orm_where(c Cond) orm.QueryData {
	mut data := orm.QueryData{}
	if c.junction != .true {
		add_where(mut data, c, true)
	}
	return data
}

fn add_where(mut data orm.QueryData, c Cond, top bool) {
	if c.junction == .leaf {
		data.fields << c.column
		data.kinds << c.kind
		if c.kind !in [.is_null, .is_not_null] {
			// IS NULL and IS NOT NULL take no value
			data.data << c.value
			data.types << primitive_type(c.value)
		}
		return
	}
	first := data.fields.len
	for i, child in c.children {
		if i > 0 {
			data.is_and << (c.junction == .and)
		}
		add_where(mut data, child, false)
	}
	if !top && data.fields.len - first > 1 {
		data.parentheses << [first, data.fields.len - 1]
	}
}

fn is_empty_list(value orm.Primitive) bool {
	return match value {
		[]int { value.len == 0 }
		[]i64 { value.len == 0 }
		[]string { value.len == 0 }
		else { false }
	}
}

// Params collects the parameters of a statement for a dialect, as text.
pub struct Params {
pub:
	dialect orm.SQLDialect
pub mut:
	values []string
}

// add returns the placeholder for `value`, and keeps the value as a parameter.
// A null is written into the SQL, since drivers take parameters as text, and
// on SQLite a number is cast from it.
pub fn (mut p Params) add(value orm.Primitive) !string {
	if value is orm.Null {
		return 'NULL'
	}
	p.values << param_text(p.dialect, value)!
	if p.dialect == .pg {
		return '\$${p.values.len}'
	}
	// SQLite reads a text parameter as a number only next to a column of that
	// type; cast, so a number is one anywhere, as in raw SQL
	return match value {
		bool, i8, i16, int, i64, u8, u16, u32, u64, time.Time { 'CAST(? AS INTEGER)' }
		f32, f64 { 'CAST(? AS REAL)' }
		else { '?' }
	}
}

// param_text returns `value` as text, stored the way V's ORM stores it: on
// SQLite, booleans as 0 or 1 and times as Unix seconds.
pub fn param_text(dialect orm.SQLDialect, value orm.Primitive) !string {
	return match value {
		bool {
			if dialect == .pg {
				if value { 'true' } else { 'false' }
			} else {
				if value { '1' } else { '0' }
			}
		}
		time.Time {
			if dialect == .pg { value.format_ss_micro() } else { value.unix().str() }
		}
		string {
			value
		}
		i8, i16, int, i64, u8, u16, u32, u64 {
			value.str()
		}
		f32, f64 {
			value.str()
		}
		else {
			error('vgraph cannot pass a ${value.type_name()} as a parameter')
		}
	}
}

// quote returns `name` as an SQL identifier, which SQLite and PostgreSQL both
// read.
pub fn quote(name string) string {
	return '"${name.replace('"', '""')}"'
}

// render returns `c`, normalized, as SQL, with its values in `p`.
fn render(c Cond, mut p Params) !string {
	text := match c.junction {
		.true {
			'1 = 1'
		}
		.false {
			'1 = 0'
		}
		.and, .or {
			mut parts := []string{}
			for child in c.children {
				parts << render(child, mut p)!
			}
			'(${parts.join(if c.junction == .and { ' AND ' } else { ' OR ' })})'
		}
		.not {
			'NOT (${render(c.children[0], mut p)!})'
		}
		.raw {
			mut text := ''
			mut n := 0
			for i := 0; i < c.raw.len; i++ {
				if c.raw[i] == `?` {
					if n >= c.args.len {
						return error('raw SQL `${c.raw}` has more `?` than arguments')
					}
					text += p.add(c.args[n])!
					n++
				} else {
					text += c.raw[i].ascii_str()
				}
			}
			if n != c.args.len {
				return error('raw SQL `${c.raw}` has fewer `?` than arguments')
			}
			'(${text})'
		}
		.sub {
			s := c.sub[0]
			mut conds := s.conds.clone()
			// a null in the list would make NOT IN match nothing
			conds << is_not_null(s.column)
			where := render(normalize(and(...conds), false), mut p)!
			'${quote(c.column)} IN (SELECT ${quote(s.column)} FROM ${quote(s.table)} WHERE ${where})'
		}
		.leaf {
			render_leaf(c, mut p)!
		}
	}
	if c.negate && c.junction in [.leaf, .sub, .raw] {
		return 'NOT (${text})'
	}
	return text
}

fn render_leaf(c Cond, mut p Params) !string {
	column := if c.fold { 'LOWER(${quote(c.column)})' } else { quote(c.column) }
	op := match c.kind {
		.eq { '=' }
		.neq { '<>' }
		.lt { '<' }
		.le { '<=' }
		.gt { '>' }
		.ge { '>=' }
		.orm_like { 'LIKE' }
		.orm_ilike { 'ILIKE' }
		.is_null { 'IS NULL' }
		.is_not_null { 'IS NOT NULL' }
		.in { 'IN' }
		.not_in { 'NOT IN' }
	}
	if c.kind in [.is_null, .is_not_null] {
		return '${column} ${op}'
	}
	if c.kind in [.in, .not_in] {
		mut items := []string{}
		match c.value {
			[]int {
				for v in c.value {
					items << p.add(v)!
				}
			}
			[]i64 {
				for v in c.value {
					items << p.add(v)!
				}
			}
			[]string {
				for v in c.value {
					items << p.add(v)!
				}
			}
			else {
				return error('`${c.column}`: IN needs a list')
			}
		}
		return '${column} ${op} (${items.join(', ')})'
	}
	value := if c.fold { 'LOWER(${p.add(c.value)!})' } else { p.add(c.value)! }
	escape := if c.escape { " ESCAPE '\\'" } else { '' }
	return '${column} ${op} ${value}${escape}'
}

// Raw is a vgraph driver as `load` sees it: one that runs SQL with parameters.
// `vgraph.Driver` has these methods.
interface Raw {
	orm.Connection
	dialect() orm.SQLDialect
mut:
	exec_params(query string, params []string) ![][]?string
}

// resolve returns `c` with each subquery replaced by the values it selects,
// read first through the ORM, for a connection without a driver.
fn resolve(conn orm.Connection, c Cond) !Cond {
	match c.junction {
		.and, .or, .not {
			mut children := []Cond{cap: c.children.len}
			for child in c.children {
				children << resolve(conn, child)!
			}
			return Cond{
				...c
				children: children
			}
		}
		.sub {
			s := c.sub[0]
			mut conds := s.conds.clone()
			conds << is_not_null(s.column)
			values := select_column(conn, s.table, s.column, s.kind, resolve(conn, and(...conds))!)!
			list := in_keys(c.column, values, s.kind)
			return if c.negate { not(list) } else { list }
		}
		else {
			return c
		}
	}
}

// select_column returns the distinct values of `column` of the rows of `table`
// that match `where`, as strings, through the ORM.
fn select_column(conn orm.Connection, table string, column string, kind KeyType, where Cond) ![]string {
	root := normalize(where, false)
	if root.junction == .false {
		return []string{}
	}
	if !orm_ready(root) {
		return error(needs_driver)
	}
	data := orm_where(root)
	config := orm.SelectConfig{
		table:        orm.Table{
			name: table
		}
		has_where:    data.fields.len > 0
		has_distinct: true
		primary:      column
		fields:       [column]
		select_exprs: [column]
		types:        [orm_type(kind)]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, data)!
	return rows.map(cell_key(it[0], column) or { '' })
}

const needs_driver = "this query needs SQL the ORM can't run: pass a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg)"
