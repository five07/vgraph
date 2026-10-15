module main

import five07.otel.exporters.otlphttp
import five07.otel.exporters.stdout
import five07.otel.sdk.trace

// new_provider returns the tracer provider of the app, with one processor per
// exporter in `exporters`, which `OTEL_TRACES_EXPORTER` names: `otlp` sends
// spans in batches to the collector the `OTEL_EXPORTER_OTLP_*` variables name
// (by default http://localhost:4318), and `console` prints each one to stdout
// as it ends. Both can be on at once. The resource, the sampler and the limits
// come from the other `OTEL_*` variables, such as `OTEL_SERVICE_NAME`.
fn new_provider(exporters []string) !&trace.TracerProvider {
	mut processors := []trace.SpanProcessor{}
	for name in exporters {
		match name {
			'otlp' {
				processors << trace.BatchSpanProcessor.new(otlphttp.Exporter.new()!)
			}
			'console' {
				processors << trace.SimpleSpanProcessor.new(stdout.Exporter.new())
			}
			else {
				return error('no exporter `${name}`')
			}
		}
	}
	return trace.TracerProvider.new(processors: processors)!
}
