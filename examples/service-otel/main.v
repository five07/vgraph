module main

import os
import veb
import five07.otel
import five07.vgraph
import app

fn main() {
	cfg := app.load_config('.env') or {
		eprintln('config: ${err}')
		exit(1)
	}
	// with exporters, a tracer provider; without, the graph records nothing,
	// and its GraphQL server says so when it starts
	mut opts := vgraph.ClientOptions{}
	if cfg.traces_exporters.len > 0 {
		provider := new_provider(cfg.traces_exporters) or {
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
