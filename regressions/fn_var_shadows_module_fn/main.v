// A local variable holding a function, named like a function of an imported
// module, is called as that module's function: `validate(value)` below
// generates `validate(&value)`, taking `helper.validate`'s `&Doc` parameter,
// and the C doesn't compile (`passing 'orm__Primitive *' to parameter of
// incompatible type`). The module's function is only reachable as
// `helper.validate`, so the variable should win. The module needn't be imported
// where the variable is: in vgraph, a closure named `fail` in `field.v` was
// called as `fail` of `examples/service`'s `app` module, which only the app
// imports.
// Run: `v run .` in this folder. Expect `checked x`.
// Worked around in `field.v` by naming the variables `custom` and `invalid`.
module main

import helper
import orm

struct Field {
	validate ?fn (value orm.Primitive) !
}

fn (f Field) check(value orm.Primitive) ! {
	if validate := f.validate {
		validate(value)!
	}
}

fn main() {
	_ = helper.Doc{}
	f := Field{
		validate: fn (value orm.Primitive) ! {
			println('checked ${value as string}')
		}
	}
	f.check(orm.Primitive('x'))!
}
