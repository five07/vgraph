module vgraph

import context
import orm
import os
import five07.otel
import five07.otel.semconv

// OpenTelemetry: vgraph records spans through `five07.otel`'s API, with the
// provider the app gives `Client.new`. Without one, it records nothing.

// version is vgraph's, which its tracer reports.
pub const version = '0.2.0'

// OtelLevel is how much a model's generated code records.
pub enum OtelLevel {
	// none: no spans; the generated code has none (the level of a model
	// without an `otel()` method)
	none
	// ops: a span per query, write and edge load
	ops
	// full: `ops`, and spans for hooks, interceptors, privacy rules and
	// GraphQL resolvers
	full
	// default: generated as `full`; the client's level applies, which the app
	// chooses when it runs (`ClientOptions.otel_level`)
	default
}

// Otel are a model's telemetry options, which its `otel()` method gives.
pub struct Otel {
pub:
	level OtelLevel
}

// Instrumented is implemented by structs that give telemetry options. vgraph
// finds the method through reflection, so declaring it is enough.
pub interface Instrumented {
	otel() Otel
}

// ClientOptions set up a client's telemetry.
@[params]
pub struct ClientOptions {
pub:
	// tracer_provider records the client's spans; with none, the client
	// records nothing
	tracer_provider ?otel.TracerProvider
	// otel_level is the level of the models whose level is `default`: by
	// default `VGRAPH_OTEL_LEVEL` (`none`, `ops` or `full`), else `ops`
	otel_level ?OtelLevel
	// trace_statements records a span per database statement, when there is a
	// provider
	trace_statements bool = true
}

// otel_level returns the level of the models whose level is `default`: the
// one `opts` gives, else `VGRAPH_OTEL_LEVEL`'s, else `ops`. An unknown value
// of the variable is a warning, and is ignored.
fn otel_level(opts ClientOptions) !OtelLevel {
	if level := opts.otel_level {
		if level == .default {
			return error("ClientOptions.otel_level: give `none`, `ops` or `full`; `default` is a model's level")
		}
		return level
	}
	value := os.getenv('VGRAPH_OTEL_LEVEL').trim_space().to_lower()
	return match value {
		'' {
			OtelLevel.ops
		}
		'none', 'ops', 'full' {
			OtelLevel.from(value) or { OtelLevel.ops }
		}
		else {
			eprintln('vgraph: VGRAPH_OTEL_LEVEL is `${value}`, not `none`, `ops` or `full`; using `ops`')
			OtelLevel.ops
		}
	}
}

// records reports whether a model of level `level` records the spans of
// `wanted` (`ops` or `full`) on this client: never without a provider, and a
// `default` model by the client's level.
pub fn (c Client) records(level OtelLevel, wanted OtelLevel) bool {
	if !c.has_tracer_provider {
		return false
	}
	actual := if level == .default { c.otel_level } else { level }
	return match wanted {
		.ops { actual in [.ops, .full] }
		.full { actual == .full }
		else { false }
	}
}

// statement_spans returns the tracer that records each statement of a
// connection as a span, timed when the statement ran, under the span of the
// client's context.
fn statement_spans(tracer otel.Tracer, system string) Tracer {
	return fn [tracer, system] (e TraceEvent) {
		operation, target := statement_names(e)
		mut attrs := []otel.KeyValue{}
		if system != '' {
			attrs << otel.string_attr(semconv.db_system_name, system)
		}
		if target != '' {
			attrs << otel.string_attr(semconv.db_collection_name, target)
		}
		if operation != '' {
			attrs << otel.string_attr(semconv.db_operation_name, operation)
		}
		if e.statement != '' {
			attrs << otel.string_attr(semconv.db_query_text, e.statement)
		}
		name := if operation != '' && target != '' {
			'${operation} ${target}'
		} else if operation != '' {
			operation
		} else if target != '' {
			target
		} else if system != '' {
			system
		} else {
			'SQL'
		}
		_, span := tracer.start(e.ctx, name,
			kind:       .client
			start:      e.started
			attributes: attrs
		)
		if e.failed {
			span.set_status(code: .error)
		}
		span.end(end: e.started.add(e.duration))
	}
}

// statement_names returns a statement's operation, such as `SELECT`, and the
// table it is on: from its kind and table, or for the SQL vgraph writes
// itself, from the statement, whose names vgraph quotes. A raw statement of
// the app's has neither, since its SQL isn't read.
fn statement_names(e TraceEvent) (string, string) {
	match e.kind {
		.select { return 'SELECT', e.table }
		.insert { return 'INSERT', e.table }
		.update { return 'UPDATE', e.table }
		.delete { return 'DELETE', e.table }
		.ddl { return '', e.table }
		.begin { return 'BEGIN', '' }
		.commit { return 'COMMIT', '' }
		.rollback { return 'ROLLBACK', '' }
		.raw {}
	}
	if e.statement == '' {
		return '', ''
	}
	operation := e.statement.all_before(' ').to_upper()
	keyword := match operation {
		'INSERT' { ' INTO "' }
		'UPDATE' { 'UPDATE "' }
		else { ' FROM "' }
	}
	at := e.statement.index(keyword) or { return operation, '' }
	return operation, quoted_name(e.statement[at + keyword.len..])
}

// quoted_name returns the name at the start of `s`, which follows its opening
// quote: up to the closing one, with each doubled quote one quote.
fn quoted_name(s string) string {
	mut name := []u8{}
	mut i := 0
	for i < s.len {
		if s[i] == `"` {
			if i + 1 < s.len && s[i + 1] == `"` {
				name << `"`
				i += 2
				continue
			}
			break
		}
		name << s[i]
		i++
	}
	return name.bytestr()
}

// db_system returns the semantic conventions' name of the database `conn`
// runs on, from a vgraph driver's dialect. Of an ORM connection, V gives no
// more than its type's bare name, such as `DB`, so it returns ''.
fn db_system(conn orm.Connection) string {
	if conn is Driver {
		return match conn.dialect() {
			.sqlite { 'sqlite' }
			.pg { 'postgresql' }
			.mysql { 'mysql' }
			else { '' }
		}
	}
	return ''
}

// The attributes of vgraph's own spans.
const vgraph_operation = 'vgraph.operation'
const vgraph_edge = 'vgraph.edge'
const vgraph_batch_size = 'vgraph.batch_size'
const vgraph_rows = 'vgraph.rows'
const vgraph_hook = 'vgraph.hook'
const vgraph_interceptor = 'vgraph.interceptor'
const vgraph_decision = 'vgraph.decision'
const vgraph_field = 'vgraph.field'

// start_span starts the span `name` of the operation `op` on `table`, for a
// model of level `level`, and returns the client to run the operation with,
// whose context holds the span. When the client doesn't record the model's
// operations, it returns the client as it is and a span that records nothing.
// The generated code calls it; `end_span` ends the span.
pub fn (c Client) start_span(level OtelLevel, name string, table string, op string) (Client, otel.Span) {
	if !c.records(level, .ops) {
		return c, otel.noop_span()
	}
	ctx, span := c.tracer.start(c.ctx, name,
		attributes: [otel.string_attr(semconv.db_collection_name, table),
			otel.string_attr(vgraph_operation, op)]
	)
	return c.with_span_ctx(ctx), span
}

// start_load_span starts the span of the load of `table`'s edge `edge` for
// `parents` rows, as `start_span` does.
pub fn (c Client) start_load_span(level OtelLevel, table string, edge string, parents int) (Client, otel.Span) {
	if !c.records(level, .ops) {
		return c, otel.noop_span()
	}
	ctx, span := c.tracer.start(c.ctx, 'load ${table}.${edge}',
		attributes: [otel.string_attr(semconv.db_collection_name, table),
			otel.string_attr(vgraph_operation, 'load'), otel.string_attr(vgraph_edge, edge),
			otel.int_attr(vgraph_batch_size, parents)]
	)
	return c.with_span_ctx(ctx), span
}

// span_rows records on `span` how many rows its operation returned.
pub fn span_rows(span otel.Span, rows int) {
	if span.is_recording() {
		span.set_attributes(otel.int_attr(vgraph_rows, rows))
	}
}

// span_failed records on `span` that its operation failed with `err`: the
// error's type, not its message, which can quote values.
pub fn span_failed(span otel.Span, err IError) {
	if span.is_recording() {
		span.record_error(err)
		span.set_status(code: .error)
	}
}

// with_span_ctx returns the client with `ctx`, the context of a span it
// started, in place of its own: unlike `with_ctx`, it doesn't look for a
// transaction in it, which the client already runs in when there is one.
fn (c Client) with_span_ctx(ctx context.Context) Client {
	return Client{
		...c
		conn: with_trace_ctx(c.conn, ctx)
		ctx:  ctx
	}
}

// full_spans reports whether the client records the hooks, interceptors and
// privacy rules of `table`: its model is `full`, or `default` on a `full`
// client.
fn (c Client) full_spans(table string) bool {
	if !c.has_tracer_provider {
		return false
	}
	t := c.schema.tables[table] or { return false }
	return c.records(t.otel.level, .full)
}

// traced_run returns the `run` of the hook `h` of `table` with a span around
// it, which covers the hook and what runs after it: the hooks inside it and
// the write. The span's context goes on to them, so their queries and
// statements are its children. A hook that doesn't apply to a write has no span.
fn (c Client) traced_run(table string, h Hook) fn (Mutate) Mutate {
	return fn [c, table, h] (next Mutate) Mutate {
		return c.traced_hook(table, h, h.run(next))
	}
}

fn (c Client) traced_hook(table string, h Hook, chain Mutate) Mutate {
	tracer := c.tracer
	name := if h.name == 'privacy' { 'privacy ${table}' } else { 'hook ${table}' }
	return fn [tracer, name, table, h, chain] (ctx context.Context, mut m Mutation) ! {
		mut attrs := [otel.string_attr(semconv.db_collection_name, table),
			otel.string_attr(vgraph_operation, m.operation().str())]
		if h.name != '' && h.name != 'privacy' {
			attrs << otel.string_attr(vgraph_hook, h.name)
		}
		span_ctx, span := tracer.start(ctx, name, attributes: attrs)
		defer {
			span.end()
		}
		chain(span_ctx, mut m) or {
			span_failed(span, err)
			return err
		}
	}
}
