#!/usr/bin/env -S v run

// Makes this checkout importable as `five07.vgraph`, which the examples and the
// generator need, and checks that `five07.otel`, which vgraph imports, is there
// too. Without them, V stops on their imports with `cannot import module
// "five07.vgraph" (not found)` before any of their own code runs, so the check
// can't live in the examples themselves.
//
//   v run examples/setup.vsh
//
// It links the checkout into the module folder when nothing is there, and leaves
// alone a `five07.vgraph` that is already installed, saying which one V will use.
// It links an `otel` checkout beside this one as `five07.otel` when that is
// missing, or says where to get it.
import os

// link makes `target` importable as `five07.<name>`, and reports whether it did.
fn link(target string, name string) bool {
	module_link := os.join_path(os.vmodules_dir(), 'five07', name)
	os.mkdir_all(os.dir(module_link)) or {
		eprintln('cannot create ${os.dir(module_link)}: ${err}')
		return false
	}
	os.symlink(target, module_link) or {
		eprintln('cannot link ${module_link} to ${target}: ${err}')
		eprintln('Link it yourself, or copy the checkout there.')
		return false
	}
	println('Linked ${module_link} -> ${target}.')
	return true
}

checkout := os.real_path(os.dir(os.dir(@FILE)))
mut ok := true
mut vgraph_installed := false
for vmodules in os.vmodules_paths() {
	installed := os.join_path(vmodules, 'five07', 'vgraph')
	if !os.exists(installed) {
		continue
	}
	vgraph_installed = true
	if os.real_path(installed) == checkout {
		println('five07.vgraph is this checkout (${installed}).')
	} else {
		eprintln('five07.vgraph is ${os.real_path(installed)}, not this checkout (${checkout}).')
		eprintln('The examples would build against that one. To use this checkout instead:')
		eprintln('  rm ${installed} && v run ${@FILE}')
		ok = false
	}
	break
}
if !vgraph_installed {
	ok = link(checkout, 'vgraph') && ok
}

mut otel_installed := false
for vmodules in os.vmodules_paths() {
	installed := os.join_path(vmodules, 'five07', 'otel')
	if os.exists(installed) {
		println('five07.otel is ${os.real_path(installed)}.')
		otel_installed = true
		break
	}
}
if !otel_installed {
	sibling := os.join_path(os.dir(checkout), 'otel')
	if os.read_file(os.join_path(sibling, 'v.mod')) or { '' }.contains("name: 'otel'") {
		ok = link(sibling, 'otel') && ok
	} else {
		eprintln('five07.otel, which vgraph imports, is not installed. Clone it beside this checkout')
		eprintln('and run this again, or into the module folder yourself:')
		eprintln('  git clone https://github.com/five07/otel ${os.join_path(os.vmodules_dir(), 'five07', 'otel')}')
		ok = false
	}
}

if !ok {
	exit(1)
}
println('The examples will build.')
