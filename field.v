module vgraph

import orm
import regex
import time

// Field gives options to one field of a struct, by its V name. A struct lists
// the fields that need options in a `fields()` method, beside `edges()`; the
// others are inferred: an option type is optional on create, a `@[sql: serial]`
// key is set by the database, and every other field is required on create.
//
// The checks (`not_empty` to `validate`) run on every value a create or an
// update sets, except null.
pub struct Field {
pub:
	name string @[required]
	// optional: a create may leave the field unset, so the database's default
	// applies.
	optional bool
	// immutable: only a create sets the field; the update builders have no
	// setter for it.
	immutable bool
	// sensitive: the field is left out of the GraphQL schema.
	sensitive bool
	// unique: the migration helpers give the field a unique index.
	unique bool
	// graphql_skip leaves the field out of the GraphQL schema, as
	// `@[graphql: '-']` does.
	graphql_skip bool
	comment      string
	deprecated   string // the reason the field is deprecated
	// default gives the value of a create that leaves the field unset.
	default ?fn () orm.Primitive
	// default_now sets a `time.Time` field to the current time on create, when
	// it is unset.
	default_now bool
	// update_default gives the value of an update that leaves the field unset.
	update_default ?fn () orm.Primitive
	// update_now sets a `time.Time` field to the current time on each update
	// that leaves it unset.
	update_now bool
	// checks on strings
	not_empty bool
	min_len   int    // in bytes; no minimum when 0
	max_len   int    // in bytes; no maximum when 0
	pattern   string // a regular expression the whole value must match
	// checks on numbers
	min      ?f64
	max      ?f64
	positive bool
	// validate checks a value as the ORM sees it: an `int`, `string`, and so on.
	validate ?fn (value orm.Primitive) !
	// json: a `string` field holding JSON, and the V type it decodes to, such as
	// `[]string` or a struct of the model's module
	json string
}

// Fields is implemented by structs that give options to their fields. vgraph
// finds the method through reflection, so declaring it is enough.
pub interface Fields {
	fields() []Field
}

// ValidationError is the error of a write whose value for a field is missing,
// fails a check, or may not be set.
pub struct ValidationError {
	Error
pub:
	table   string
	field   string // the column
	message string
}

// msg names the column and what is wrong with its value.
pub fn (e ValidationError) msg() string {
	return '`${e.table}.${e.field}`: ${e.message}'
}

// check_options reports the options of `table` that name no field, or don't
// fit the field's type.
fn check_options(mut problems []string, table Table, options []Field) {
	mut seen := map[string]bool{}
	for o in options {
		at := '${table.name}.fields: `${o.name}`'
		if o.name in seen {
			problems << '${at} is listed twice'
		}
		seen[o.name] = true
		mut column := ?Column(none)
		for c in table.columns {
			if c.field == o.name {
				column = c
			}
		}
		c := column or {
			problems << '${at} is not a field of `${table.struct_}`'
			continue
		}
		base := c.typ.trim_left('?')
		if (o.default_now || o.update_now) && base != 'time.Time' {
			problems << '${at}: `default_now` and `update_now` need a time.Time field'
		}
		if (o.not_empty || o.min_len > 0 || o.max_len > 0 || o.pattern != '') && base != 'string' {
			problems << '${at}: `not_empty`, `min_len`, `max_len` and `pattern` need a string field'
		}
		has_range := o.min != none || o.max != none
		if (has_range || o.positive) && base !in ['int', 'i64', 'f64'] {
			problems << '${at}: `min`, `max` and `positive` need a number field'
		}
		if o.immutable && (o.update_now || o.update_default != none) {
			problems << '${at}: an immutable field has no update default'
		}
		if o.pattern != '' {
			regex.regex_opt(o.pattern) or {
				problems << '${at}: `pattern` is not a valid regular expression: ${err.msg()}'
			}
		}
		if o.json != '' && base != 'string' {
			problems << '${at}: `json` needs a string field, which holds the JSON'
		}
		if c.name == table.key && (o.update_now || o.update_default != none) {
			problems << '${at}: the key has no update default'
		}
	}
}

// with_options returns `c` with the data of its options, `o`, so that it can
// be printed for `vgraph gen`.
fn (c Column) with_options(o Field) Column {
	return Column{
		...c
		optional:     c.optional || o.optional || o.default != none || o.default_now
		immutable:    o.immutable
		sensitive:    o.sensitive
		unique:       c.unique || o.unique
		graphql_skip: c.graphql_skip || o.graphql_skip || o.sensitive
		comment:      o.comment
		deprecated:   o.deprecated
		has_default:  o.default != none || o.default_now
		auto_update:  o.update_now || o.update_default != none
		json_type:    o.json
	}
}

// check runs the checks of `o` on `value`, which is set and not null.
fn (o Field) check(table string, column string, value orm.Primitive) ! {
	// not `fail`: a variable named like a function of a module the app imports
	// is called as that function (regressions/fn_var_shadows_module_fn/)
	invalid := fn [table, column] (message string) IError {
		return ValidationError{
			table:   table
			field:   column
			message: message
		}
	}
	if value is string {
		if o.not_empty && value == '' {
			return invalid('is empty')
		}
		if o.min_len > 0 && value.len < o.min_len {
			return invalid('is shorter than ${o.min_len} bytes')
		}
		if o.max_len > 0 && value.len > o.max_len {
			return invalid('is longer than ${o.max_len} bytes')
		}
		if o.pattern != '' {
			mut re := regex.regex_opt(o.pattern) or { return invalid('has an invalid pattern') }
			if !re.matches_string(value) {
				return invalid('does not match `${o.pattern}`')
			}
		}
	}
	if number := as_f64(value) {
		if min := o.min {
			if number < min {
				return invalid('is less than ${min}')
			}
		}
		if max := o.max {
			if number > max {
				return invalid('is more than ${max}')
			}
		}
		if o.positive && number <= 0 {
			return invalid('is not positive')
		}
	}
	// not `validate`: a variable named like a function that `graphql` declares
	// generates invalid C (regressions/shadowed_fn_call.vv)
	if custom := o.validate {
		custom(value) or { return invalid(err.msg()) }
	}
}

fn as_f64(value orm.Primitive) ?f64 {
	return match value {
		int { f64(value) }
		i64 { f64(value) }
		f64 { value }
		else { none }
	}
}

// now is the time `default_now` and `update_now` set.
fn now() orm.Primitive {
	return time.now()
}
