module main

import os
import veb
import five07.otel
import five07.otel.exporters.autoconfig
import five07.otel.sdk.trace
import five07.vgraph
import app

fn main() {
	cfg := app.load_config('.env') or {
		eprintln('config: ${err}')
		exit(1)
	}
	// a processor per exporter `OTEL_TRACES_EXPORTER` names: `otlp` sends spans
	// in batches to the collector the `OTEL_EXPORTER_OTLP_*` variables name (by
	// default http://localhost:4318), and `console` prints each one to stdout
	// as it ends. Both can be on at once.
	processors := autoconfig.processors_from_env() or {
		eprintln('tracing: ${err}')
		exit(1)
	}
	// with exporters, a tracer provider, which the other `OTEL_*` variables,
	// such as `OTEL_SERVICE_NAME`, set up; without, the graph records nothing,
	// and its GraphQL server says so when it starts
	mut opts := vgraph.ClientOptions{}
	if processors.len > 0 {
		provider := trace.TracerProvider.new(processors: processors) or {
			eprintln('tracing: ${err}')
			exit(1)
		}
		opts = vgraph.ClientOptions{
			tracer_provider: otel.TracerProvider(provider)
		}
		// on ctrl-c, send the spans still queued before exiting
		os.signal_opt(.int, fn [provider] (_ os.Signal) {
			provider.shutdown() or { eprintln('tracing: ${err}') }
			exit(0)
		}) or {}
	}
	mut api := new_app(cfg, opts) or {
		eprintln('startup: ${err}')
		exit(1)
	}
	veb.run_at[App, app.Context](mut api, port: cfg.port) or {
		eprintln('server: ${err}')
		exit(1)
	}
}
