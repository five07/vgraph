// vtest build: vgraph_pg?
module main

// Every Ent relationship kind on PostgreSQL. The checks are in `checks.v`. It
// runs only with `-d vgraph_pg`, and reads `PGHOST`, `PGPORT`, `PGUSER`,
// `PGPASSWORD` and `PGDATABASE`. It drops and recreates the tables it uses.
import context
import db.pg
import five07.vgraph.pg as vpg
import os
import five07.vgraph.graphql
import graph
import models

const relation_tables = ['schema_migrations', 'vgraph_types', 'likes', 'gadgets', 'users', 'cards',
	'pets', 'groups', 'group_users', 'follows', 'friendships', 'nodes', 'categories', 'devices',
	'logins', 'device_groups']

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
	db.exec('DROP VIEW IF EXISTS pet_owners')!
	for table in relation_tables {
		db.exec('DROP TABLE IF EXISTS "${table}" CASCADE')!
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

fn test_queries() {
	check_queries(fixture()!)!
}

fn test_schema() {
	check_schema(fixture()!)!
}

fn test_relay() {
	check_relay(fixture()!)!
}

fn test_nested_connections() {
	check_nested_connections(fixture()!)!
}

fn test_where_input() {
	check_where_input(fixture()!)!
}

fn test_mutations() {
	check_mutations(fixture()!)!
}

fn test_fixed_selects() {
	check_fixed_selects(fixture()!)!
}

// A GraphQL request's mutations on a pool: they run on the connection of the
// request's transaction, so a failure rolls back every one of them.
fn test_graphql_transaction_on_a_pool() {
	fixture()!
	mut db := pg.connect(pg.Config{
		host:     os.getenv_opt('PGHOST') or { 'localhost' }
		port:     (os.getenv_opt('PGPORT') or { '5432' }).int()
		user:     os.getenv_opt('PGUSER') or { 'postgres' }
		password: os.getenv_opt('PGPASSWORD') or { '12345678' }
		dbname:   os.getenv_opt('PGDATABASE') or { 'postgres' }
	})!
	defer {
		db.close() or {}
	}
	g := graph.Graph.new(vpg.pool(db))!
	s := g.graphql(graph.Resolvers{})!
	// the second mutation is denied (only an admin deletes a group): the first
	// one's group is gone with it
	denied := s.execute(graphql.Request{
		query: 'mutation { a: createGroup(input: {name: "ops"}) { id } b: createUser(input: {name: "gil", groupIDs: ["1"]}) { id } c: deleteGroup(id: "2") }'
	}, context.background())
	assert denied.errors.map(it.message) == ['privacy: delete_one of `groups` denied']
	assert g.groups().where_name('ops').count()! == 0
	assert g.users().where_name('gil').count()! == 0
	assert g.groups().count()! == 2
	// as an admin, all three, committed together
	allowed := s.execute(graphql.Request{
		query: 'mutation { a: createGroup(input: {name: "ops"}) { id } b: createUser(input: {name: "gil", groupIDs: ["1"]}) { groups { name } } c: deleteGroup(id: "2") }'
	}, models.as_admin())
	assert allowed.errors.len == 0
	assert g.groups().order_by_id().all()!.map(it.group.name) == ['admins', 'ops']
	assert g.users().where_name('gil').with_groups().only()!.groups.map(it.group.name) == ['admins']
}
