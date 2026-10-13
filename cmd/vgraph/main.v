// vgraph is the command line tool of vgraph. `vgraph gen` writes the typed client
// for the structs of a project that declare edges.
module main

import os
import gen

const usage = "usage: vgraph gen [project folder] [--out <module>] [--no-graphql]
       vgraph describe [project folder]

Finds the structs with an `edges() []vgraph.Edge` method in the project, checks
their schema, and writes the typed client module `<module>` (default `graph`) into
the project folder (default `.`), which must hold the `v.mod`.

It also writes the GraphQL schema of the tables, merged with the project's own
`.graphql` files, as `<module>/schema.graphql`, and the server that resolves it,
`Graph.graphql()`. The fields the files add are resolved by the methods of
`Resolvers` in `<module>/resolvers.v`: a file vgraph gen creates, then only adds
stubs to. With --no-graphql, it writes neither.

`vgraph describe` prints the schema: each table's columns, edges and indexes."

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] !in ['gen', 'describe'] || '-h' in args || '--help' in args {
		println(usage)
		exit(if args.len > 0 && args[0] in ['-h', '--help'] { 0 } else { 1 })
	}
	mut root := '.'
	mut out := 'graph'
	mut graphql := true
	mut i := 1
	for i < args.len {
		if args[i] == '--out' && i + 1 < args.len {
			out = args[i + 1]
			i += 2
			continue
		}
		if args[i] == '--no-graphql' {
			graphql = false
			i++
			continue
		}
		root = args[i]
		i++
	}
	if args[0] == 'describe' {
		text := describe_project(os.real_path(root), out) or {
			eprintln('vgraph describe: ${err.msg()}')
			exit(1)
		}
		print(text)
		return
	}
	run(os.real_path(root), out, graphql) or {
		eprintln('vgraph gen: ${err.msg()}')
		exit(1)
	}
}

// describe_project returns the schema of the project at `root`, as text.
fn describe_project(root string, out string) !string {
	if !os.exists(os.join_path(root, 'v.mod')) {
		return error('${root} has no v.mod')
	}
	entities := gen.discover(root, [out])!
	if entities.len == 0 {
		return error('no struct in ${root} has an `edges() []vgraph.Edge` method')
	}
	return gen.describe(entities, gen.decode_tables(run_loader(root, entities)!)!)
}

fn run(root string, out string, with_graphql bool) ! {
	if !os.exists(os.join_path(root, 'v.mod')) {
		return error('${root} has no v.mod')
	}
	entities := gen.discover(root, [out])!
	if entities.len == 0 {
		return error('no struct in ${root} has an `edges() []vgraph.Edge` method')
	}
	tables := gen.decode_tables(run_loader(root, entities)!)!
	mut files := gen.generate(out, entities, tables)!

	dir := os.join_path(root, out)
	os.mkdir_all(dir)!
	// the GraphQL schema and server; resolvers.v is the project's, and only
	// gains stubs for new fields
	resolvers_path := os.join_path(dir, 'resolvers.v')
	current := if os.exists(resolvers_path) { os.read_file(resolvers_path)! } else { '' }
	mut defined := ''
	for name in os.ls(dir)! {
		path := os.join_path(dir, name)
		if name.ends_with('.v') && name != 'resolvers.v'
			&& !os.read_file(path)!.starts_with(gen.header) {
			defined += os.read_file(path)!
		}
	}
	mut g := gen.GraphqlOutput{}
	if with_graphql {
		graphql_files := gen.read_graphql_files(root, [out])!
		g = gen.generate_graphql(out, entities, tables, graphql_files, current, defined)!
		files['graphql.v'] = g.server
	}
	// remove generated files that are no longer generated
	for name in os.ls(dir)! {
		path := os.join_path(dir, name)
		if name.ends_with('.v') && name !in files
			&& os.read_file(path)!.starts_with(gen.header) {
			os.rm(path)!
		}
	}
	mut names := files.keys()
	names.sort()
	for name in names {
		os.write_file(os.join_path(dir, name), files[name])!
	}
	if with_graphql {
		os.write_file(os.join_path(dir, 'schema.graphql'), g.schema)!
	}
	if g.resolvers != '' {
		os.write_file(resolvers_path, g.resolvers)!
	}
	res := os.exec([v_exe(), 'fmt', '-w', dir])
	if res.exit_code != 0 {
		return error('formatting the generated code failed:\n${res.output}')
	}
	and_schema := if with_graphql { ' and schema.graphql' } else { '' }
	println('vgraph gen: wrote ${names.len} files${and_schema} to ${dir} for ${entities.len} tables')
	for stub in g.stubs {
		println('vgraph gen: added a stub to ${out}/resolvers.v for ${stub}; implement it')
	}
}

// run_loader compiles and runs a program that registers `entities` and prints
// the checked schema, and returns what it prints.
fn run_loader(root string, entities []gen.Entity) !string {
	dir := os.join_path(root, '.vgraph-gen')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'main.v'), gen.loader_source(entities))!
	// imports resolve from the `v.mod` above the loader, not the working folder
	res := os.exec([v_exe(), 'run', dir])
	if res.exit_code == 2 {
		return error('the schema has problems:\n${res.output.trim_space()}')
	}
	if res.exit_code != 0 {
		return error('reading the schema failed:\n${res.output}')
	}
	// the JSON is the last line; the compiler may print notices before it
	return res.output.trim_space().split_into_lines().last()
}

fn v_exe() string {
	return os.getenv_opt('VEXE') or { @VEXE }
}
