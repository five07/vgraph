module main

// Every Ent relationship kind on SQLite. The checks are in `checks.v`.
import db.sqlite
import five07.vgraph.sqlite as vsqlite

fn fixture() !Fixture {
	mut db := sqlite.connect(':memory:')!
	migrate(mut db, .sqlite)!
	return seed(db, vsqlite.new(db))!
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
