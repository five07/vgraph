module app

import os

fn test_parse_env() {
	values := parse_env('
# a comment
DB_PATH = "data/app.db"
export PORT=9000
DB_DRIVER=\'sqlite\'
EMPTY=
URL=a=b
')!
	assert values == {
		'DB_PATH':   'data/app.db'
		'PORT':      '9000'
		'DB_DRIVER': 'sqlite'
		'EMPTY':     ''
		'URL':       'a=b'
	}
}

fn test_parse_env_rejects_a_line_without_equals() {
	parse_env('PORT=1\nnonsense\n') or {
		assert err.msg() == '.env line 2: expected KEY=VALUE'
		return
	}
	assert false, 'expected an error'
}

fn test_config_defaults() {
	cfg := config_from({})!
	assert cfg == Config{
		db_driver: 'sqlite'
		db_path:   ':memory:'
		port:      8080
		seed:      true
	}
	assert !config_from({
		'SEED': 'false'
	})!.seed
	assert config_from({
		'SEED': '1'
	})!.seed
	assert config_from({
		'DB_PATH': ''
	})!.db_path == ':memory:'
}

fn test_config_rejects_bad_values() {
	for values in [{
		'PORT': 'abc'
	}, {
		'PORT': '0'
	}, {
		'PORT': '70000'
	}, {
		'PORT': '80x'
	}, {
		'DB_DRIVER': 'pg'
	}, {
		'SEED': 'yes'
	}] {
		config_from(values) or { continue }
		assert false, 'expected an error for ${values}'
	}
}

fn test_load_config_reads_the_file_and_the_environment_overrides_it() {
	dir := os.join_path(os.vtmp_dir(), 'example-config-test-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, '.env')
	os.write_file(path, 'DB_PATH=file.db\nPORT=9000\n')!

	os.unsetenv('DB_PATH')
	os.unsetenv('PORT')
	os.unsetenv('DB_DRIVER')
	os.unsetenv('SEED')
	assert load_config(path)! == Config{
		db_path: 'file.db'
		port:    9000
	}

	os.setenv('PORT', '9100', true)
	defer {
		os.unsetenv('PORT')
	}
	assert load_config(path)!.port == 9100
	assert load_config(os.join_path(dir, 'missing.env'))! == Config{
		port: 9100
	}
}
