module main

// The checks on SQLite, through vgraph's driver, each on a database of its
// own.
import db.sqlite
import five07.vgraph
import five07.vgraph.sqlite as vsqlite
import catalog
import checks
import graph

fn fixture() !checks.Fixture {
	mut db := sqlite.connect(':memory:')!
	catalog.migrate(mut db, .sqlite, 'schema_migrations')!
	log := &checks.Log{}
	g := graph.Graph.new(vgraph.trace(vsqlite.new(db), checks.log_to(log)))!
	catalog.seed(g)!
	return checks.new_fixture(g, log)!
}

fn test_lists() {
	checks.check_lists(fixture()!)!
}

fn test_connections() {
	checks.check_connections(fixture()!)!
}

fn test_nested() {
	checks.check_nested(fixture()!)!
}

fn test_statements() {
	checks.check_statements(fixture()!)!
}

fn test_page_sizes() {
	checks.check_page_sizes(fixture()!)!
}

fn test_writes_between_pages() {
	checks.check_writes_between_pages(fixture()!)!
}

// The app's own setup, which `v run .` serves: migrated and seeded once.
fn test_new_app() {
	mut db := sqlite.connect(':memory:')!
	new_app(mut db)!
	new_app(mut db)!
	assert db.exec('SELECT count(*) FROM books')![0].vals[0] == '300'
	mut links := 0
	for id in checks.all_books() {
		links += catalog.book_authors(id).len
	}
	assert db.exec('SELECT count(*) FROM book_authors')![0].vals[0] == links.str()
}
