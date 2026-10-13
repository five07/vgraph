// vtest build: vgraph_pg?
module main

// Every Ent relationship kind on PostgreSQL. The checks are in `checks.v`. It
// runs only with `-d vgraph_pg`, and reads `PGHOST`, `PGPORT`, `PGUSER`,
// `PGPASSWORD` and `PGDATABASE`. It drops and recreates the tables it uses.
import db.pg
import five07.vgraph.pg as vpg
import os

const relation_tables = ['schema_migrations', 'users', 'cards', 'pets', 'groups', 'group_users',
	'follows', 'friendships', 'nodes', 'categories', 'devices', 'logins', 'device_groups']

fn fixture() !Fixture {
	// v.migrations runs on a direct connection, not a pool
	mut db := pg.connect_direct(pg.Config{
		host:     os.getenv_opt('PGHOST') or { 'localhost' }
		port:     (os.getenv_opt('PGPORT') or { '5432' }).int()
		user:     os.getenv_opt('PGUSER') or { 'postgres' }
		password: os.getenv_opt('PGPASSWORD') or { '12345678' }
		dbname:   os.getenv_opt('PGDATABASE') or { 'postgres' }
	})!
	db.exec('SET client_min_messages = warning')!
	for table in relation_tables {
		db.exec('DROP TABLE IF EXISTS "${table}"')!
	}
	migrate(mut db, .pg)!
	return seed(db, vpg.direct(db))!
}

fn test_o2o_two_types() {
	check_o2o_two_types(fixture()!)!
}

fn test_o2o_same_type() {
	check_o2o_same_type(fixture()!)!
}

fn test_o2o_bidirectional() {
	check_o2o_bidirectional(fixture()!)!
}

fn test_o2m_two_types() {
	check_o2m_two_types(fixture()!)!
}

fn test_o2m_same_type() {
	check_o2m_same_type(fixture()!)!
}

fn test_m2m_two_types() {
	check_m2m_two_types(fixture()!)!
}

fn test_m2m_same_type() {
	check_m2m_same_type(fixture()!)!
}

fn test_m2m_bidirectional() {
	check_m2m_bidirectional(fixture()!)!
}

fn test_unique_indexes() {
	check_unique_indexes(fixture()!)!
}

fn test_uuid_keys() {
	check_uuid_keys(fixture()!)!
}

fn test_graphql() {
	check_graphql(fixture()!)!
}

fn test_writes() {
	check_writes(fixture()!)!
}

fn test_soft_delete() {
	check_soft_delete(fixture()!)!
}
