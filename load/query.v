module load

import orm
import time

// Cond is one condition of a query, `column kind value`, such as `title = 'V'`.
// Conditions are joined with AND.
pub struct Cond {
pub:
	column string
	kind   orm.OperationKind
	value  orm.Primitive = orm.null_primitive
}

// eq returns the condition `column = value`.
pub fn eq(column string, value orm.Primitive) Cond {
	return Cond{column, .eq, value}
}

// ne returns the condition `column != value`.
pub fn ne(column string, value orm.Primitive) Cond {
	return Cond{column, .neq, value}
}

// lt returns the condition `column < value`.
pub fn lt(column string, value orm.Primitive) Cond {
	return Cond{column, .lt, value}
}

// le returns the condition `column <= value`.
pub fn le(column string, value orm.Primitive) Cond {
	return Cond{column, .le, value}
}

// gt returns the condition `column > value`.
pub fn gt(column string, value orm.Primitive) Cond {
	return Cond{column, .gt, value}
}

// ge returns the condition `column >= value`.
pub fn ge(column string, value orm.Primitive) Cond {
	return Cond{column, .ge, value}
}

// like returns the condition `column LIKE pattern`.
pub fn like(column string, pattern string) Cond {
	return Cond{column, .orm_like, pattern}
}

// in_ints returns the condition `column IN (values)`. An empty `values` matches
// no row.
pub fn in_ints(column string, values []int) Cond {
	return Cond{column, .in, values}
}

// in_i64s returns the condition `column IN (values)`. An empty `values` matches
// no row.
pub fn in_i64s(column string, values []i64) Cond {
	return Cond{column, .in, values}
}

// not_in_ints returns the condition `column NOT IN (values)`. An empty `values`
// matches every row.
pub fn not_in_ints(column string, values []int) Cond {
	return Cond{column, .not_in, values}
}

// not_in_strings returns the condition `column NOT IN (values)`. An empty
// `values` matches every row.
pub fn not_in_strings(column string, values []string) Cond {
	return Cond{column, .not_in, values}
}

// in_strings returns the condition `column IN (values)`. An empty `values`
// matches no row.
pub fn in_strings(column string, values []string) Cond {
	return Cond{column, .in, values}
}

// is_null returns the condition `column IS NULL`.
pub fn is_null(column string) Cond {
	return Cond{
		column: column
		kind:   .is_null
	}
}

// is_not_null returns the condition `column IS NOT NULL`.
pub fn is_not_null(column string) Cond {
	return Cond{
		column: column
		kind:   .is_not_null
	}
}

// Query narrows, orders and limits a select.
pub struct Query {
pub mut:
	conds  []Cond
	order  string // a column to order by; none when empty
	desc   bool
	limit  int // at most this many rows; no limit when 0. Edge loads ignore it.
	offset int // skip this many rows first. Edge loads ignore it.
}

// select_where returns the `T` records that match `q`, in one query.
pub fn select_where[T](conn orm.Connection, q Query) ![]T {
	conds := effective(q.conds)
	if matches_nothing(conds) {
		return []T{}
	}
	return run_select[T](conn, where_of(conds), q, true)
}

// count_where returns how many `T` records match the conditions of `q`, in one
// query. Its order, limit and offset don't apply.
pub fn count_where[T](conn orm.Connection, q Query) !int {
	conds := effective(q.conds)
	if matches_nothing(conds) {
		return 0
	}
	where := where_of(conds)
	config := orm.SelectConfig{
		table:          orm.Table{
			name: table_name[T]()
		}
		aggregate_kind: .count
		has_where:      where.fields.len > 0
		primary:        primary_key[T]()
		types:          [orm.type_idx['int']]
	}
	mut c := conn
	rows := c.select(config, orm.QueryData{}, where)!
	if rows.len == 0 || rows[0].len == 0 {
		return 0
	}
	return int(cell_i64(rows[0][0], 'count')!)
}

// where_data returns `conds`, joined with AND, as the ORM's where data, for
// writes. It returns `none` when they match no row, and drops the ones every
// row matches.
pub fn where_data(conds []Cond) ?orm.QueryData {
	kept := effective(conds)
	if matches_nothing(kept) {
		return none
	}
	return where_of(kept)
}

// value_type returns the ORM's type index for `value`.
pub fn value_type(value orm.Primitive) int {
	return primitive_type(value)
}

// effective drops the conditions that hold for every row: `NOT IN` an empty
// list, which isn't valid SQL.
fn effective(conds []Cond) []Cond {
	return conds.filter(!(it.kind == .not_in && is_empty_list(it.value)))
}

fn is_empty_list(value orm.Primitive) bool {
	return match value {
		[]int { value.len == 0 }
		[]i64 { value.len == 0 }
		[]string { value.len == 0 }
		else { false }
	}
}

// matches_nothing reports whether `conds` has an `IN ()` with no values, which
// is invalid SQL, and would match no row anyway.
fn matches_nothing(conds []Cond) bool {
	for cond in conds {
		if cond.kind in [.in, .not_in] {
			empty := match cond.value {
				[]int { cond.value.len == 0 }
				[]i64 { cond.value.len == 0 }
				[]string { cond.value.len == 0 }
				else { false }
			}
			if empty && cond.kind == .in {
				return true
			}
		}
	}
	return false
}

// where_of returns `conds`, joined with AND, as the ORM's where data.
fn where_of(conds []Cond) orm.QueryData {
	mut where := orm.QueryData{}
	for i, cond in conds {
		if i > 0 {
			where.is_and << true
		}
		where.fields << cond.column
		where.kinds << cond.kind
		if cond.kind !in [.is_null, .is_not_null] {
			// IS NULL and IS NOT NULL take no value
			where.data << cond.value
			where.types << primitive_type(cond.value)
		}
	}
	return where
}

fn primitive_type(value orm.Primitive) int {
	return match value {
		[]int { typeof[[]int]().idx }
		[]i64 { typeof[[]i64]().idx }
		[]string { typeof[[]string]().idx }
		int { orm.type_idx['int'] }
		i64 { orm.type_idx['i64'] }
		f64 { orm.type_idx['f64'] }
		bool { orm.type_idx['bool'] }
		string { orm.type_string }
		time.Time { orm.time_ }
		else { orm.type_idx['int'] }
	}
}
