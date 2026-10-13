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
pub:
	conds []Cond
	order string // a column to order by; none when empty
	desc  bool
	limit int // at most this many rows; no limit when 0. Edge loads ignore it.
}

// select_where returns the `T` records that match `q`, in one query.
pub fn select_where[T](conn orm.Connection, q Query) ![]T {
	if matches_nothing(q.conds) {
		return []T{}
	}
	return run_select[T](conn, where_of(q.conds), q, true)
}

// matches_nothing reports whether `conds` has an `IN ()` with no values, which
// is invalid SQL, and would match no row anyway.
fn matches_nothing(conds []Cond) bool {
	for cond in conds {
		if cond.kind in [.in, .not_in] {
			empty := match cond.value {
				[]int { cond.value.len == 0 }
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
