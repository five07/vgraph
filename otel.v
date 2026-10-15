module vgraph

import orm
import os
import five07.otel

// OpenTelemetry: vgraph records spans through `five07.otel`'s API, with the
// provider the app gives `Client.new`. Without one, it records nothing.

// version is vgraph's, which its tracer reports.
pub const version = '0.1.0'

// The semantic conventions' names of a database statement's attributes.
const db_system_name = 'db.system.name'
const db_collection_name = 'db.collection.name'
const db_operation_name = 'db.operation.name'
const db_query_text = 'db.query.text'

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
			attrs << otel.string_attr(db_system_name, system)
		}
		if target != '' {
			attrs << otel.string_attr(db_collection_name, target)
		}
		if operation != '' {
			attrs << otel.string_attr(db_operation_name, operation)
		}
		if e.statement != '' {
			attrs << otel.string_attr(db_query_text, e.statement)
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
