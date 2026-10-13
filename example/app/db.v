module app

import db.sqlite

// The result code SQLite reports for every constraint violation.
const sqlite_constraint = 19

// connect opens the database named by `cfg`, with foreign keys enforced:
// SQLite leaves them off for each new connection unless told otherwise.
//
// The connection is opened in serialized mode (`fullmutex`), because veb
// serves requests on several threads and every store shares this connection.
// The libsqlite3 on macOS is built in multi-thread mode, where two threads
// using one connection at once crash inside SQLite.
pub fn connect(cfg Config) !sqlite.DB {
	mut db := sqlite.connect_full(cfg.db_path, [.readwrite, .create, .fullmutex], '')!
	db.exec('PRAGMA foreign_keys = ON')!
	return db
}

// Constraint is the kind of database constraint a write broke.
pub enum Constraint {
	unique
	foreign_key
}

// constraint returns the kind of constraint that the database error `err`
// reports, or `none` when `err` is not a constraint violation. Stores use it
// to turn database errors, whose text includes the SQL, into errors fit for
// clients.
pub fn constraint(err IError) ?Constraint {
	if err.code() != sqlite_constraint {
		return none
	}
	text := err.msg()
	if text.contains('UNIQUE constraint failed') {
		return .unique
	}
	if text.contains('FOREIGN KEY constraint failed') {
		return .foreign_key
	}
	return none
}
