module main

import context
import five07.otel
import five07.otel.exporters.otlphttp
import five07.otel.exporters.stdout
import five07.otel.propagation
import five07.otel.sdk.trace
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.sqlite as vsqlite
import db.sqlite
import v.migrations
import graph

fn test_tracing() {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	mut seen := []string{}
	ptr := &seen
	// snippet: trace
	g := graph.Graph.new(vgraph.trace(vsqlite.new(db), fn [ptr] (e vgraph.TraceEvent) {
		// the kind, table, duration and failure of each statement; never values
		mut out := unsafe { ptr }
		out << '${e.kind} ${e.table}'
	}))!
	g.articles().with_author().all()!
	// end snippet
	assert seen == ['select articles']
}

// setup_tracing builds the provider the guide shows. It compiles with the
// tests, but doesn't run: its exporters would send to a collector.
fn setup_tracing(db sqlite.DB) ! {
	// snippet: provider
	// once, at startup: each span goes to stdout as it ends, and in batches to
	// the collector at OTEL_EXPORTER_OTLP_ENDPOINT (default localhost:4318)
	provider := trace.TracerProvider.new(
		processors: [
			trace.SimpleSpanProcessor.new(stdout.Exporter.new()),
			trace.BatchSpanProcessor.new(otlphttp.Exporter.new()!),
		]
	)!
	defer {
		provider.shutdown() or { eprintln(err) }
	}
	g := graph.Graph.new(vsqlite.new(db), tracer_provider: otel.TracerProvider(provider))!
	// end snippet
	_ = g
}

// recording returns the docs' blog on a client that keeps its spans in
// memory, its provider, and the exporter that holds the spans.
fn recording(opts vgraph.ClientOptions) !(graph.Graph, &trace.TracerProvider, &trace.InMemoryExporter) {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	// snippet: testing
	exporter := trace.InMemoryExporter.new()
	provider := trace.TracerProvider.new(processors: [trace.SimpleSpanProcessor.new(exporter)])!
	g := graph.Graph.new(vsqlite.new(db), vgraph.ClientOptions{
		...opts
		tracer_provider: otel.TracerProvider(provider)
	})!
	// … run the code, then read `exporter.spans()`, or one by name: `exporter.span(name)`
	// end snippet
	return g, provider, exporter
}

fn test_spans_nest_under_the_callers() {
	g, provider, exporter := recording()!
	tracer := provider.tracer('blog')
	// snippet: context
	// the app's span, such as its request's: vgraph's spans are its children
	ctx, span := tracer.start(context.background(), 'GET /comments')
	comments := g.with_ctx(ctx).comments().all()!
	span.end()
	// end snippet
	assert comments.len == 0
	spans := exporter.spans()
	assert spans.map(it.name) == ['SELECT comments', 'query comments', 'GET /comments']
	assert spans[1].is_child_of(spans.last())
	assert spans[0].is_child_of(spans[1])
}

// request_context returns the context of a request whose headers are
// `headers`: the caller's trace, when it sent one.
fn request_context(headers map[string]string) context.Context {
	// snippet: propagation
	// the caller's trace, from the request's W3C `traceparent` and `tracestate`
	parent := propagation.default_propagator().extract(context.background(),
		propagation.MapCarrier.new(headers))
	// end snippet
	return parent
}

fn test_a_request_continues_its_callers_trace() {
	g, _, exporter := recording()!
	server := g.graphql(graph.Resolvers{ g: g })!
	// building the server reads the global ids, in a trace of its own
	exporter.reset()
	ctx := request_context({
		'traceparent': '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
	})
	res := server.execute(graphql.Request{
		query: 'query Recent { comments(limit: 1) { body } }'
	}, ctx)
	assert res.errors.len == 0
	op := exporter.spans().last()
	assert op.name == 'query Recent'
	assert op.parent.span_id.hex() == 'b7ad6b7169203331'
	assert exporter.spans().all(it.span_context.trace_id.hex() == '0af7651916cd43dd8448eb211c80319c')
}
