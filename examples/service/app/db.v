module app

import db.sqlite

// connect opens the database named by `cfg`, with foreign keys enforced:
// SQLite leaves them off for each new connection unless told otherwise.
//
// The connection is opened in serialized mode (`fullmutex`), because veb
// serves requests on several threads and every query shares this connection.
// The libsqlite3 on macOS is built in multi-thread mode, where two threads
// using one connection at once crash inside SQLite.
pub fn connect(cfg Config) !sqlite.DB {
	mut db := sqlite.connect_full(cfg.db_path, [.readwrite, .create, .fullmutex], '')!
	db.exec('PRAGMA foreign_keys = ON')!
	return db
}
