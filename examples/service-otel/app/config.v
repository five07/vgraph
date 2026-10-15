module app

import os

pub const default_db_path = ':memory:'
pub const default_port = 8080

// The settings `load_config` reads, from `.env` or the environment.
const config_keys = ['DB_DRIVER', 'DB_PATH', 'PORT', 'SEED']!

// Config holds the settings of the app.
pub struct Config {
pub:
	// db_driver names the database backend. Only `sqlite` is supported for now.
	db_driver string = 'sqlite'
	// db_path is the SQLite database file, or `:memory:`.
	db_path string = default_db_path
	port    int    = default_port
	// seed loads example data at startup when the database has no users.
	seed bool = true
}

// load_config reads the settings from the `.env` file at `path`, when there is
// one, and then from the environment, which overrides the file. A setting in
// neither keeps its default.
pub fn load_config(path string) !Config {
	mut values := map[string]string{}
	if os.exists(path) {
		values = parse_env(os.read_file(path)!)!
	}
	// otel's SDK and vgraph read their settings from the environment: the
	// file's `OTEL_*` and `VGRAPH_OTEL_LEVEL` go there, unless already set
	for key, value in values {
		if (key.starts_with('OTEL_') || key == 'VGRAPH_OTEL_LEVEL') && os.getenv_opt(key) == none {
			os.setenv(key, value, false)
		}
	}
	for key in config_keys {
		if value := os.getenv_opt(key) {
			values[key] = value
		}
	}
	return config_from(values)
}

// config_from builds a `Config` from `values`, keyed by setting name, and
// checks it.
fn config_from(values map[string]string) !Config {
	driver := values['DB_DRIVER'] or { 'sqlite' }
	if driver != 'sqlite' {
		return error('DB_DRIVER `${driver}` is not supported yet; use `sqlite`')
	}
	mut db_path := values['DB_PATH'] or { default_db_path }
	if db_path == '' {
		db_path = default_db_path
	}
	mut port := default_port
	if value := values['PORT'] {
		port = value.int()
		if port < 1 || port > 65535 || port.str() != value {
			return error('PORT `${value}` is not a port number')
		}
	}
	mut seed := true
	if value := values['SEED'] {
		seed = match value {
			'true', '1' { true }
			'false', '0' { false }
			else { return error('SEED `${value}` must be `true` or `false`') }
		}
	}
	return Config{
		db_driver: driver
		db_path:   db_path
		port:      port
		seed:      seed
	}
}

// parse_env parses the `KEY=VALUE` lines of a `.env` file. Blank lines and
// lines starting with `#` are skipped, a leading `export ` is allowed, and a
// value wrapped in matching single or double quotes is unwrapped.
fn parse_env(text string) !map[string]string {
	mut values := map[string]string{}
	for i, raw in text.split_into_lines() {
		mut line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		line = line.trim_string_left('export ')
		key, value := line.split_once('=') or {
			return error('.env line ${i + 1}: expected KEY=VALUE')
		}
		values[key.trim_space()] = unquote(value.trim_space())
	}
	return values
}

// unquote removes one pair of matching quotes around `s`.
fn unquote(s string) string {
	if s.len >= 2 && s[0] == s[s.len - 1] && s[0] in [`"`, `'`] {
		return s[1..s.len - 1]
	}
	return s
}
