module main

import net
import net.http
import time
import veb
import app
import five07.otel
import five07.otel.sdk.trace
import five07.vgraph
import five07.vgraph.graphql

// The tests run the app over HTTP with its spans kept in memory, and check the
// spans each request makes: the operation's, the spans of each model's level
// under it, and the statements. They need no collector.

// Recorder is a running app and the spans it recorded.
struct Recorder {
	base     string
	exporter &trace.InMemoryExporter
}

// start runs a new app with the example data on a free port, its spans kept in
// memory. `level` is the level of posts, whose model leaves it to the app.
fn start(level vgraph.OtelLevel) !Recorder {
	exporter := trace.InMemoryExporter.new()
	provider := trace.TracerProvider.new(processors: [trace.SimpleSpanProcessor.new(exporter)])!
	cfg := app.Config{
		seed: true
		port: 0
	}
	api := new_app_on(cfg, app.connect(cfg)!,
		tracer_provider: otel.TracerProvider(provider)
		otel_level:      level
	)!
	base := serve(api)!
	// the seed's writes are spans too; the tests read a request's alone
	exporter.reset()
	return Recorder{
		base:     base
		exporter: exporter
	}
}

// serve runs `api` on a free port, and returns its base URL once it answers.
fn serve(api &App) !string {
	port := free_port()!
	mut a := unsafe { api }
	spawn veb.run_at[App, app.Context](mut a,
		port:                 port
		family:               .ip
		host:                 '127.0.0.1'
		show_startup_message: false
	)
	base := 'http://127.0.0.1:${port}'
	for _ in 0 .. 100 {
		http.get('${base}/health') or {
			time.sleep(20 * time.millisecond)
			continue
		}
		return base
	}
	return error('the app did not start on port ${port}')
}

// free_port returns a TCP port that nothing is listening on.
fn free_port() !int {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		l.close() or {}
	}
	return int(l.addr()!.port()!)
}

// request posts a GraphQL request with the headers `headers`, checks that it
// succeeded, and returns the spans of its trace.
fn (r Recorder) request(query string, headers map[string]string) ![]trace.ReadOnlySpan {
	r.exporter.reset()
	mut header := http.new_header(key: .content_type, value: 'application/json')
	for key, value in headers {
		header.add_custom(key, value)!
	}
	res := http.fetch(
		url:    '${r.base}/graphql'
		method: .post
		data:   graphql.Value({
			'query': graphql.Value(query)
		}).json()
		header: header
	)!
	assert res.status_code == 200, res.body
	assert !res.body.contains('"errors"'), res.body
	return r.exporter.spans()
}

fn span_named(spans []trace.ReadOnlySpan, name string) !trace.ReadOnlySpan {
	for s in spans {
		if s.name == name {
			return s
		}
	}
	return error('no span `${name}` in ${spans.map(it.name)}')
}

const feed = 'query Feed { users(first: 1) { edges { node { name articles(first: 2) { edges { node { title } } } posts(first: 2) { edges { node { body } } } } } } }'

// A request that carries a `traceparent` continues the caller's trace: its
// operation's span is a child of the caller's span, and every span of the
// request is in the caller's trace.
fn test_a_request_continues_the_callers_trace() {
	r := start(.ops)!
	spans := r.request(feed, {
		'traceparent': '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
	})!
	op := span_named(spans, 'query Feed')!
	assert op.parent.trace_id.hex() == '0af7651916cd43dd8448eb211c80319c'
	assert op.parent.span_id.hex() == 'b7ad6b7169203331'
	assert spans.all(it.span_context.trace_id.hex() == '0af7651916cd43dd8448eb211c80319c')
	// without one, the request starts a trace of its own
	fresh := r.request(feed, {})!
	assert !span_named(fresh, 'query Feed')!.parent.is_valid()
}

// Each model records the spans of its level: users (`full`) their resolvers,
// queries and interceptors; articles (`ops`) their loads; comments (no
// `otel()`) only their statements.
fn test_each_model_records_its_level() {
	r := start(.ops)!
	spans := r.request(feed, {})!
	op := span_named(spans, 'query Feed')!
	assert op.kind == .server
	users := span_named(spans, 'resolve Query.users')!
	assert users.is_child_of(op)
	query := span_named(spans, 'query users')!
	assert query.is_child_of(users)
	assert span_named(spans, 'intercept users')!.is_child_of(query)
	assert span_named(spans, 'SELECT users')!.is_child_of(query)
	// articles are ops: a load, under the resolver of the user's field, which
	// is the user's, and their statements under it
	load := span_named(spans, 'load users.articles')!
	assert load.is_child_of(span_named(spans, 'resolve User.articles')!)
	assert span_named(spans, 'SELECT articles')!.is_child_of(load)
	assert 'resolve Article.title' !in spans.map(it.name)
	// comments: their query has no span, its statement is the operation's
	comments := r.request('{ comments(first: 1) { edges { node { body } } } }', {})!
	assert 'query comments' !in comments.map(it.name)
	assert 'resolve Query.comments' !in comments.map(it.name)
	assert span_named(comments, 'SELECT comments')!.is_child_of(span_named(comments, 'query')!)
}

// Posts are `default`: the app chooses their level when it starts, here
// through the client's `otel_level`, as `VGRAPH_OTEL_LEVEL` does.
fn test_posts_follow_the_apps_level() {
	ops := start(.ops)!
	at_ops := ops.request('{ posts(first: 1) { edges { node { body } } } }', {})!
	assert 'query posts' in at_ops.map(it.name)
	assert 'resolve Query.posts' !in at_ops.map(it.name)
	full := start(.full)!
	at_full := full.request('{ posts(first: 1) { edges { node { body } } } }', {})!
	assert span_named(at_full, 'query posts')!.is_child_of(span_named(at_full, 'resolve Query.posts')!)
	assert 'intercept posts' in at_full.map(it.name)
	none_ := start(.none)!
	at_none := none_.request('{ posts(first: 1) { edges { node { body } } } }', {})!
	assert 'query posts' !in at_none.map(it.name)
}

// A mutation is a span; its transaction, its write and the write's hooks are
// under it, and the write's statement under the innermost hook.
fn test_a_mutation_and_its_hooks() {
	r := start(.ops)!
	spans := r.request('mutation Join { createUser(input: {name: " Edsger ", email: "EDSGER@example.com"}) { name } }', {})!
	op := span_named(spans, 'mutation Join')!
	resolver := span_named(spans, 'resolve Mutation.createUser')!
	assert resolver.is_child_of(op)
	assert span_named(spans, 'BEGIN')!.is_child_of(op)
	assert span_named(spans, 'COMMIT')!.is_child_of(op)
	create := span_named(spans, 'create users')!
	assert create.is_child_of(resolver)
	// users have two hooks, but the soft delete runs on deletes alone: a
	// create has one hook span, and the statement under it
	hooks := spans.filter(it.name == 'hook users')
	assert hooks.len == 1
	assert hooks[0].is_child_of(create)
	assert span_named(spans, 'INSERT users')!.is_child_of(hooks[0])
	// nothing in a span is a value of the request
	for s in spans {
		for kv in s.attributes {
			assert !kv.value.str().contains('EDSGER'), '${s.name} ${kv.key}'
		}
	}
}
