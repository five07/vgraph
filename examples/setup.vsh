#!/usr/bin/env -S v run

// Makes this checkout importable as `five07.vgraph`, which the examples and the
// generator need. Without it, V stops on their imports with `cannot import module
// "five07.vgraph" (not found)` before any of their own code runs, so the check
// can't live in the examples themselves.
//
//   v run examples/setup.vsh
//
// It links the checkout into the module folder when nothing is there, and leaves
// alone a `five07.vgraph` that is already installed, saying which one V will use.
import os

checkout := os.real_path(os.dir(os.dir(@FILE)))
for vmodules in os.vmodules_paths() {
	installed := os.join_path(vmodules, 'five07', 'vgraph')
	if !os.exists(installed) {
		continue
	}
	if os.real_path(installed) == checkout {
		println('five07.vgraph is this checkout (${installed}); the examples will build.')
		exit(0)
	}
	eprintln('five07.vgraph is ${os.real_path(installed)}, not this checkout (${checkout}).')
	eprintln('The examples would build against that one. To use this checkout instead:')
	eprintln('  rm ${installed} && v run ${@FILE}')
	exit(1)
}

module_link := os.join_path(os.vmodules_dir(), 'five07', 'vgraph')
os.mkdir_all(os.dir(module_link)) or {
	eprintln('cannot create ${os.dir(module_link)}: ${err}')
	exit(1)
}
os.symlink(checkout, module_link) or {
	eprintln('cannot link ${module_link} to ${checkout}: ${err}')
	eprintln('Link it yourself, or copy the checkout there.')
	exit(1)
}
println('Linked ${module_link} -> ${checkout}; the examples will build.')
