module main

import veb
import app

fn main() {
	cfg := app.load_config('.env') or {
		eprintln('config: ${err}')
		exit(1)
	}
	mut api := new_app(cfg) or {
		eprintln('startup: ${err}')
		exit(1)
	}
	veb.run_at[App, app.Context](mut api, port: cfg.port) or {
		eprintln('server: ${err}')
		exit(1)
	}
}
