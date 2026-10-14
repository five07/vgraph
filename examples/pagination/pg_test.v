// vtest build: vgraph_pg?
module main

// The checks on PostgreSQL. It runs only with `-d vgraph_pg`, and reads
// `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE`. It drops and
// recreates the tables it uses.
import db.pg
import five07.vgraph
import five07.vgraph.pg as vpg
import os
import catalog
import checks
import graph

fn fixture() !checks.Fixture {
	// v.migrations runs on a direct connection, not a pool
	mut db := pg.connect_direct(pg.Config{
		host:     os.getenv_opt('PGHOST') or { 'localhost' }
		port:     (os.getenv_opt('PGPORT') or { '5432' }).int()
		user:     os.getenv_opt('PGUSER') or { 'postgres' }
		password: os.getenv_opt('PGPASSWORD') or { '12345678' }
		dbname:   os.getenv_opt('PGDATABASE') or { 'postgres' }
	})!
	db.exec('SET client_min_messages = warning')!
	for table in ['pagination_migrations', 'book_authors', 'books', 'authors'] {
		db.exec('DROP TABLE IF EXISTS "${table}" CASCADE')!
	}
	catalog.migrate(mut db, .pg, 'pagination_migrations')!
	log := &checks.Log{}
	g := graph.Graph.new(vgraph.trace(vpg.direct(db), checks.log_to(log)))!
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
