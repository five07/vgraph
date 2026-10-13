module load

import orm
import time

// eq returns the condition `column = value`.
pub fn eq(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .eq
		value:  value
	}
}

// ne returns the condition `column != value`.
pub fn ne(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .neq
		value:  value
	}
}

// lt returns the condition `column < value`.
pub fn lt(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .lt
		value:  value
	}
}

// le returns the condition `column <= value`.
pub fn le(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .le
		value:  value
	}
}

// gt returns the condition `column > value`.
pub fn gt(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .gt
		value:  value
	}
}

// ge returns the condition `column >= value`.
pub fn ge(column string, value orm.Primitive) Cond {
	return Cond{
		column: column
		kind:   .ge
		value:  value
	}
}

// like returns the condition `column LIKE pattern`.
pub fn like(column string, pattern string) Cond {
	return Cond{
		column: column
		kind:   .orm_like
		value:  pattern
	}
}

// in_ints returns the condition `column IN (values)`. An empty `values` matches
// no row.
pub fn in_ints(column string, values []int) Cond {
	return Cond{
		column: column
		kind:   .in
		value:  values
	}
}

// in_i64s returns the condition `column IN (values)`. An empty `values` matches
// no row.
pub fn in_i64s(column string, values []i64) Cond {
	return Cond{
		column: column
		kind:   .in
		value:  values
	}
}

// not_in_ints returns the condition `column NOT IN (values)`. An empty `values`
// matches every row.
pub fn not_in_ints(column string, values []int) Cond {
	return Cond{
		column: column
		kind:   .not_in
		value:  values
	}
}

// not_in_strings returns the condition `column NOT IN (values)`. An empty
// `values` matches every row.
pub fn not_in_strings(column string, values []string) Cond {
	return Cond{
		column: column
		kind:   .not_in
		value:  values
	}
}

// not_in_i64s returns the condition `column NOT IN (values)`. An empty `values`
// matches every row.
pub fn not_in_i64s(column string, values []i64) Cond {
	return Cond{
		column: column
		kind:   .not_in
		value:  values
	}
}

// in_strings returns the condition `column IN (values)`. An empty `values`
// matches no row.
pub fn in_strings(column string, values []string) Cond {
	return Cond{
		column: column
		kind:   .in
		value:  values
	}
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

// Query narrows, orders, limits and locks a select.
pub struct Query {
pub mut:
	conds []Cond
	// order and desc: the first order column, as before `orders`
	order string
	desc  bool
	// orders: the order columns after `order`
	orders []Order
	limit  int // at most this many rows; no limit when 0. Edge loads ignore it.
	offset int // skip this many rows first. Edge loads ignore it.
	lock   Lock
	// distinct: `scan` reads each distinct row once
	distinct bool
	// columns: only these columns are read, besides the key; all when empty
	columns []string
}

// Nulls is where an order puts nulls.
pub enum Nulls {
	default // the database's way: last ascending on PostgreSQL, first on SQLite
	first
	last
}

// Order is one order column, or an SQL expression (`expr`), which may name the
// table being read as `t0`.
pub struct Order {
pub:
	column string
	desc   bool
	nulls  Nulls
	expr   string
}

// asc returns the ascending order of `column`.
pub fn asc(column string) Order {
	return Order{
		column: column
	}
}

// desc returns the descending order of `column`.
pub fn desc(column string) Order {
	return Order{
		column: column
		desc:   true
	}
}

// nulls_first returns `o`, with nulls before the other values.
pub fn (o Order) nulls_first() Order {
	return Order{
		...o
		nulls: .first
	}
}

// nulls_last returns `o`, with nulls after the other values.
pub fn (o Order) nulls_last() Order {
	return Order{
		...o
		nulls: .last
	}
}

// LockMode is the row lock a select takes, in a transaction.
pub enum LockMode {
	off
	update // FOR UPDATE
	share  // FOR SHARE
}

// Lock is a select's row lock: its mode, and what it does with rows another
// transaction locked.
pub struct Lock {
pub:
	mode        LockMode
	no_wait     bool
	skip_locked bool
}

// all_orders returns the order columns of `q`, `order` first.
pub fn (q Query) all_orders() []Order {
	mut all := []Order{}
	if q.order != '' {
		all << Order{
			column: q.order
			desc:   q.desc
		}
	}
	all << q.orders
	return all
}

// select_where returns the `T` records that match `q`: one query when the ORM
// can run it, else, through a vgraph driver, the matching keys first and then
// their rows.
pub fn select_where[T](conn orm.Connection, q Query) ![]T {
	return select_rows[T](conn, table_name[T](), q.conds, q, true)
}

// count_where returns how many `T` records match the conditions of `q`, in one
// query. Its order, limit and offset don't apply.
pub fn count_where[T](conn orm.Connection, q Query) !int {
	return int(aggregate_where(conn, table_name[T](), primary_key[T](), q, .count, '')!)
}

// where_data returns `conds`, joined with AND, as the ORM's where data, for
// writes. It returns `none` when they match no row. The ORM must be able to
// run them.
pub fn where_data(conds []Cond) ?orm.QueryData {
	root := normalize(and(...conds), false)
	if root.junction == .false || !orm_ready(root) {
		return none
	}
	return orm_where(root)
}

// value_type returns the ORM's type index for `value`.
pub fn value_type(value orm.Primitive) int {
	return primitive_type(value)
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
