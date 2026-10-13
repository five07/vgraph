module vgraph

import orm
import time

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

// quote returns `name` as an SQL identifier, which SQLite and PostgreSQL both
// read.
fn quote(name string) string {
	return '"${name.replace('"', '""')}"'
}

// Params collects the parameters of a statement for a dialect.
struct Params {
	dialect orm.SQLDialect
mut:
	values []string
}

// add returns the placeholder for `value`, and keeps the value as a parameter.
// A null is written into the SQL, since drivers take parameters as text.
fn (mut p Params) add(value orm.Primitive) !string {
	if value is orm.Null {
		return 'NULL'
	}
	p.values << param_text(p.dialect, value)!
	return if p.dialect == .pg { '\$${p.values.len}' } else { '?' }
}

// param_text returns `value` as text, stored the way V's ORM stores it: on
// SQLite, booleans as 0 or 1 and times as Unix seconds.
fn param_text(dialect orm.SQLDialect, value orm.Primitive) !string {
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
