module vgraph

import load
import orm

// Driver runs the SQL that `orm.Connection` can't express, such as an insert
// that returns the new row's key, or an upsert. vgraph builds the SQL and its
// parameters; a driver only runs them. The adapters in `five07.vgraph.sqlite`
// and `five07.vgraph.pg` wrap V's database connections in one, and pass every
// ORM call through, so `Graph.new` takes the adapter in place of the
// connection.
//
// vgraph works on a connection without a driver too: writes then read new keys
// back with `last_id()` (`int` keys only), and upserts are refused.
pub interface Driver {
	orm.Connection
	dialect() orm.SQLDialect
	// exec_params runs `query` with `params` in place of its placeholders (`?`
	// on SQLite, `$1`, `$2` and so on on PostgreSQL), and returns its rows,
	// each cell as text. SQLite returns a null cell as ''.
mut:
	exec_params(query string, params []string) ![][]?string
	// begin_tx starts a transaction and returns the connection that runs in
	// it, which implements `Driver` and `TxConnection`.
	begin_tx() !orm.Connection
}

// TxConnection ends the transaction of a connection that `Driver.begin_tx`
// returned.
pub interface TxConnection {
	orm.Connection
mut:
	commit_tx() !
	rollback_tx() !
}

// asc returns the ascending order of `column`, for `order_by`.
pub fn asc(column string) load.Order {
	return load.asc(column)
}

// desc returns the descending order of `column`, for `order_by`.
pub fn desc(column string) load.Order {
	return load.desc(column)
}

// count returns the number of rows of a group, named `count`.
pub fn count() load.Aggregate {
	return load.count()
}

// sum returns the sum of `column` in a group, named `sum_<column>`.
pub fn sum(column string) load.Aggregate {
	return load.sum(column)
}

// mean returns the mean of `column` in a group, named `mean_<column>`.
pub fn mean(column string) load.Aggregate {
	return load.mean(column)
}

// min_of returns the least `column` of a group, named `min_<column>`.
pub fn min_of(column string) load.Aggregate {
	return load.min_of(column)
}

// max_of returns the greatest `column` of a group, named `max_<column>`.
pub fn max_of(column string) load.Aggregate {
	return load.max_of(column)
}

// Group is one group of a `group_by`: its columns' values, and its aggregates
// by name.
pub type Group = load.Group
