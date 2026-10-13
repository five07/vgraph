module app

fn test_connect_enforces_foreign_keys() {
	db := connect(Config{})!
	rows := db.exec('PRAGMA foreign_keys')!
	assert rows[0].vals == ['1']
}

fn test_constraint() {
	db := connect(Config{})!
	db.exec('CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT UNIQUE)')!
	db.exec('CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id))')!
	db.exec("INSERT INTO parents (name) VALUES ('a')")!

	mut kinds := []string{}
	// `exec` ignores errors raised while a statement runs; `exec_param_many` reports them.
	db.exec_param_many("INSERT INTO parents (name) VALUES ('a')", []string{}) or {
		kinds << name(constraint(err))
	}
	db.exec_param_many('INSERT INTO children (parent_id) VALUES (99)', []string{}) or {
		kinds << name(constraint(err))
	}
	db.exec('SELECT * FROM missing') or { kinds << name(constraint(err)) }
	kinds << name(constraint(error('plain')))
	assert kinds == ['unique', 'foreign_key', 'none', 'none']
}

// name returns the name of the constraint `c`, or `none` without one.
fn name(c ?Constraint) string {
	kind := c or { return 'none' }
	return kind.str()
}
