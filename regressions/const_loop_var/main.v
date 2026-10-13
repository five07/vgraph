// A `for` loop variable in one module is rejected when the main module has a
// const of the same name: `helper/helper.v:5:6: error: duplicate of a const
// name `usage``. Consts are per module, so this should compile. A plain local
// variable, or a closure capture, of that name is fine.
// Run: `v run .` in this folder. Expect `usage: tool` and `3`.
// Worked around in `graphql/rules.v` by naming the loop variable `use`.
module main

import helper

const usage = 'usage: tool'

fn main() {
	println(usage)
	println(helper.count())
}
