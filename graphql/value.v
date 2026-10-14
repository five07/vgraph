module graphql

import json2
import strings

// Value is a GraphQL value at run time: an argument or variable after coercion, a
// field's result, or a whole response. Enum values are strings, and maps keep
// their keys in insertion order, which is the order of a response's fields.
pub type Value = Null | bool | int | f64 | string | []Value | map[string]Value

// Null is the null value.
pub struct Null {}

// null is the null value, for comparisons such as `v == graphql.null`.
pub const null = Value(Null{})

// str returns a string value as it is, and any other value as JSON, so values
// interpolate naturally.
pub fn (v Value) str() string {
	if v is string {
		return v
	}
	return v.json()
}

// as_string returns a string value, or ''.
pub fn (v Value) as_string() string {
	return if v is string { v } else { '' }
}

// as_int returns an Int value, or 0.
pub fn (v Value) as_int() int {
	return match v {
		int { v }
		f64 { int(v) }
		else { 0 }
	}
}

// as_float returns a Float or Int value, or 0.
pub fn (v Value) as_float() f64 {
	return match v {
		f64 { v }
		int { f64(v) }
		else { 0 }
	}
}

// as_bool returns a Boolean value, or false.
pub fn (v Value) as_bool() bool {
	return if v is bool { v } else { false }
}

// as_list returns a list value, or an empty list.
pub fn (v Value) as_list() []Value {
	return if v is []Value { v } else { []Value{} }
}

// as_map returns an input object value, or an empty map.
pub fn (v Value) as_map() map[string]Value {
	return if v is map[string]Value { v.clone() } else { map[string]Value{} }
}

// parse_json parses JSON into a value: integers that fit in 32 bits become
// ints, other numbers floats.
pub fn parse_json(text string) !Value {
	return value_from_any(json2.decode[json2.Any](text)!)
}

// value_from_any converts a decoded JSON value.
pub fn value_from_any(a json2.Any) Value {
	return match a {
		json2.Null {
			null
		}
		bool {
			Value(a)
		}
		string {
			Value(a)
		}
		f64, f32 {
			f := f64(a)
			if f == f64(i64(f)) && f >= min_int && f <= max_int {
				Value(int(f))
			} else {
				Value(f)
			}
		}
		i64, int, i32, i16, i8, u64, u32, u16, u8 {
			n := a.i64()
			if n >= min_int && n <= max_int {
				Value(int(n))
			} else {
				Value(f64(n))
			}
		}
		[]json2.Any {
			Value(a.map(value_from_any(it)))
		}
		map[string]json2.Any {
			mut out := map[string]Value{}
			for k, v in a {
				out[k] = value_from_any(v)
			}
			Value(out)
		}
		else {
			Value(a.str())
		}
	}
}

// is_null reports whether `v` is null.
pub fn (v Value) is_null() bool {
	return v is Null
}

// json returns `v` as JSON, keys in their order.
pub fn (v Value) json() string {
	mut b := strings.new_builder(256)
	write_json(mut b, v)
	return b.str()
}

fn write_json(mut b strings.Builder, v Value) {
	match v {
		Null {
			b.write_string('null')
		}
		bool {
			b.write_string(if v { 'true' } else { 'false' })
		}
		int {
			b.write_string(v.str())
		}
		f64 {
			b.write_string(float_json(v))
		}
		string {
			write_json_string(mut b, v)
		}
		[]Value {
			b.write_u8(`[`)
			for i, item in v {
				if i > 0 {
					b.write_u8(`,`)
				}
				write_json(mut b, item)
			}
			b.write_u8(`]`)
		}
		map[string]Value {
			b.write_u8(`{`)
			mut first := true
			for key, item in v {
				if !first {
					b.write_u8(`,`)
				}
				first = false
				write_json_string(mut b, key)
				b.write_u8(`:`)
				write_json(mut b, item)
			}
			b.write_u8(`}`)
		}
	}
}

// float_json writes a float as JSON does: integral values without a fraction,
// as JavaScript prints them.
fn float_json(f f64) string {
	if f == f64(i64(f)) && f < 1e21 && f > -1e21 {
		return i64(f).str()
	}
	return f.str()
}

fn write_json_string(mut b strings.Builder, s string) {
	b.write_u8(`"`)
	for c in s {
		match c {
			`"` {
				b.write_string('\\"')
			}
			`\\` {
				b.write_string('\\\\')
			}
			`\n` {
				b.write_string('\\n')
			}
			`\r` {
				b.write_string('\\r')
			}
			`\t` {
				b.write_string('\\t')
			}
			`\b` {
				b.write_string('\\b')
			}
			`\f` {
				b.write_string('\\f')
			}
			else {
				if c < 0x20 {
					b.write_string('\\u00')
					b.write_u8('0123456789abcdef'[c >> 4])
					b.write_u8('0123456789abcdef'[c & 0xf])
				} else {
					b.write_u8(c)
				}
			}
		}
	}
	b.write_u8(`"`)
}
