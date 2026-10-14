// In a generic function of a module that imports another module with a
// struct named `Status` (here `v.migrations`), a field whose type is the
// caller's enum named `Status` passes `$if field.typ is $struct`: the type is
// looked up by its short name. An enum with another name doesn't.
// Run: `v run .` in this folder. It prints `['status: enum', 'stage: enum']`
// once fixed; now `['status: struct', 'stage: enum']`.
// Worked around in `vgraph/schema.v` (`Schema.add`): the test for an enum
// comes before the test for a struct, so an app's `Status` enum isn't taken
// for a relation and dropped.
module main

import lib

enum Status {
	draft
	published
}

enum Stage {
	draft
	published
}

struct Row {
	status Status
	stage  Stage
}

fn main() {
	println(lib.kinds[Row]())
}
