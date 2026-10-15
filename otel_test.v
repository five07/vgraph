module vgraph

import context
import db.sqlite as sq
import load
import orm
import os
import sqlite
import five07.otel.sdk.trace as sdk

@[table: 'shelves']
struct Shelf {
	id   int @[primary; sql: serial]
	name string
}

fn (s Shelf) edges() []Edge {
	return [
		Edge{
			name:   'books'
			kind:   .one_to_many
			to:     'books'
			column: 'shelf_id'
		},
	]
}

@[table: 'books']
struct Book {
	id       int @[primary; sql: serial]
	shelf_id int
	title    string
}

fn (b Book) edges() []Edge {
	return []
}

fn otel_schema() !Schema {
	mut s := Schema{}
	s.add[Shelf]()!
	s.add[Book]()!
	return s
}

fn otel_db() !sq.DB {
	db := sq.connect(':memory:')!
	sql db {
		create table Shelf
		create table Book
	}!
	return db
}

// recorder returns a provider that keeps its spans, and the exporter that
// holds them.
fn recorder() !(&sdk.TracerProvider, &sdk.InMemoryExporter) {
	exporter := sdk.InMemoryExporter.new()
	provider := sdk.TracerProvider.new(processors: [sdk.SimpleSpanProcessor.new(exporter)])!
	return provider, exporter
}

fn attr(span sdk.ReadOnlySpan, key string) string {
	for kv in span.attributes {
		if kv.key == key {
			value := kv.value
			return if value is string { value } else { value.str() }
		}
	}
	return ''
}

fn add_book(c Client, title string) !string {
	return c.create(MutationData{
		op:     .create
		table:  'books'
		values: {
			'shelf_id': orm.Primitive(1)
			'title':    orm.Primitive(title)
		}
	})
}

fn test_without_a_provider_nothing_is_traced() {
	c := Client.new(otel_db()!, otel_schema()!)!
	assert !c.has_tracer_provider
	assert c.conn !is Traced
	assert !c.records(.full, .ops)
	assert !c.records(.default, .ops)
}

// Each statement is a span, a child of the span in the client's context,
// timed when it ran, with the database's attributes and none of its values.
fn test_statements_are_spans_under_the_callers_span() {
	for driver in [false, true] {
		provider, exporter := recorder()!
		db := otel_db()!
		conn := if driver { orm.Connection(sqlite.new(db)) } else { orm.Connection(db) }
		c := Client.new(conn, otel_schema()!, tracer_provider: provider)!
		assert c.has_tracer_provider
		assert (c.conn is Driver) == driver
		tracer := provider.tracer('app')
		ctx, request := tracer.start(context.background(), 'request')
		in_request := c.with_ctx(ctx)
		add_book(in_request, 'secret title')!
		load.select_where[Book](in_request.conn, load.Query{})!
		request.end()
		spans := exporter.spans()
		root := spans.last()
		assert root.name == 'request'
		statements := spans#[..-1]
		for s in statements {
			assert s.parent.span_id == root.span_context.span_id, s.name
			assert s.kind == .client
			assert s.scope.name == 'five07.vgraph'
			assert s.scope.version == version
			// only a driver knows its database
			assert attr(s, db_system_name) == if driver { 'sqlite' } else { '' }
			assert s.end_ns >= s.start_ns
			for kv in s.attributes {
				assert !attr(s, kv.key).contains('secret')
			}
		}
		names := statements.map(it.name)
		if driver {
			assert names == ['BEGIN', 'INSERT books', 'COMMIT', 'SELECT books']
			insert := statements[1]
			assert attr(insert, db_query_text).starts_with('INSERT INTO "books" (')
		} else {
			assert names == ['BEGIN', 'INSERT books', 'COMMIT', 'SELECT books']
			assert attr(statements[1], db_query_text) == ''
		}
		assert attr(statements[1], db_collection_name) == 'books'
		assert attr(statements[1], db_operation_name) == 'INSERT'
		assert attr(statements[3], db_operation_name) == 'SELECT'
	}
}

fn test_a_failed_statement_is_an_error() {
	provider, exporter := recorder()!
	c := Client.new(otel_db()!, otel_schema()!, tracer_provider: provider)!
	mut conn := c.conn
	conn.select(orm.SelectConfig{
		table: orm.Table{
			name: 'missing'
		}
	}, orm.QueryData{}, orm.QueryData{}) or {}
	failed := exporter.spans().last()
	assert failed.name == 'SELECT missing'
	assert failed.status.code == .error
	// the status has no description: an error's message can quote values
	assert failed.status.description == ''
}

fn test_statement_spans_can_be_off() {
	provider, exporter := recorder()!
	c := Client.new(otel_db()!, otel_schema()!,
		tracer_provider:  provider
		trace_statements: false
	)!
	assert c.has_tracer_provider
	assert c.conn !is Traced
	load.select_where[Book](c.conn, load.Query{})!
	assert exporter.spans().len == 0
}

// The app's own tracer, under vgraph's spans, gets the client's context too.
fn test_the_apps_tracer_gets_the_context_under_the_spans() {
	provider, exporter := recorder()!
	mut seen := []bool{}
	log := &seen
	key := 'request'
	traced := trace(otel_db()!, fn [log, key] (e TraceEvent) {
		mut l := unsafe { log }
		l << (e.ctx.value(key) != none)
	})
	c := Client.new(traced, otel_schema()!, tracer_provider: provider)!
	load.select_where[Book](c.with_ctx(context.with_value(context.background(), key,
		true)).conn, load.Query{})!
	assert seen == [true]
	assert exporter.spans().map(it.name) == ['SELECT books']
}

fn test_otel_level_comes_from_the_options_then_the_environment() {
	os.unsetenv('VGRAPH_OTEL_LEVEL')
	assert otel_level(ClientOptions{})! == .ops
	assert otel_level(otel_level: .full)! == .full
	os.setenv('VGRAPH_OTEL_LEVEL', 'Full', true)
	assert otel_level(ClientOptions{})! == .full
	assert otel_level(otel_level: .none)! == .none
	os.setenv('VGRAPH_OTEL_LEVEL', 'loud', true)
	assert otel_level(ClientOptions{})! == .ops
	os.unsetenv('VGRAPH_OTEL_LEVEL')
	otel_level(otel_level: .default) or {
		assert err.msg().contains('`default` is a model')
		return
	}
	assert false
}

// records: a model's own level is fixed; a `default` model follows the
// client's; nothing records without a provider.
fn test_records_by_level() {
	provider, _ := recorder()!
	c := Client.new(otel_db()!, otel_schema()!, tracer_provider: provider, otel_level: .none)!
	assert !c.records(.none, .ops)
	assert c.records(.ops, .ops) && !c.records(.ops, .full)
	assert c.records(.full, .ops) && c.records(.full, .full)
	assert !c.records(.default, .ops)
	full := Client.new(otel_db()!, otel_schema()!, tracer_provider: provider, otel_level: .full)!
	assert full.records(.default, .ops) && full.records(.default, .full)
	ops := Client.new(otel_db()!, otel_schema()!, tracer_provider: provider)!
	assert ops.records(.default, .ops) && !ops.records(.default, .full)
}

fn names_of(kind TraceKind, statement string) string {
	operation, target := statement_names(TraceEvent{
		kind:      kind
		statement: statement
	})
	return '${operation} ${target}'
}

fn test_statement_names_of_vgraphs_own_sql() {
	assert names_of(.raw, 'UPDATE "books" SET "title" = ? WHERE "id" = ?') == 'UPDATE books'
	assert names_of(.raw, 'DELETE FROM "books" WHERE "id" IN (?, ?)') == 'DELETE books'
	assert names_of(.raw, 'SELECT "id" FROM "books" WHERE "shelf_id" = ?') == 'SELECT books'
	assert names_of(.raw, 'INSERT INTO "a ""b""" ("x") VALUES (?)') == 'INSERT a "b"'
	// an app's raw SQL isn't read
	assert names_of(.raw, '') == ' '
	assert names_of(.commit, '') == 'COMMIT '
}
