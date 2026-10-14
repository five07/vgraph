// Package graphql is a GraphQL server library: a lexer and parser for the whole
// language (executable documents and the type system), a schema built from SDL,
// validation, an executor that resolves each level of a query in batches, and an
// HTTP handler. It follows the October 2021 spec, and matches graphql-js, the
// reference implementation that Apollo builds on, in its messages and output.
//
// It has no dependency on vgraph, so it can become a package of its own.
module graphql

// Location is a line and column in a source, both counted from 1. Columns count
// UTF-16 code units, as graphql-js does, so they match what other GraphQL tools
// report.
pub struct Location {
pub:
	line   int
	column int
}

// location_of returns the line and column of the byte offset `pos` in `body`.
// Line breaks are `\r\n`, `\n` or `\r`; one that starts before `pos` counts,
// as in graphql-js's `getLocation`.
pub fn location_of(body string, pos int) Location {
	mut line := 1
	mut line_start := 0
	mut i := 0
	for i < body.len && i < pos {
		c := body[i]
		if c == `\n` || c == `\r` {
			size := if c == `\r` && i + 1 < body.len && body[i + 1] == `\n` { 2 } else { 1 }
			line++
			line_start = i + size
			i += size
			continue
		}
		i++
	}
	column := if line_start > pos {
		pos + 1 - line_start
	} else {
		utf16_len(body, line_start, pos) + 1
	}
	return Location{
		line:   line
		column: column
	}
}

// utf16_len returns how many UTF-16 code units the bytes `body[start..end]`
// encode. Bytes that aren't valid UTF-8 count as one each.
fn utf16_len(body string, start int, end int) int {
	mut n := 0
	mut i := start
	stop := if end < body.len { end } else { body.len }
	for i < stop {
		code, size := decode_rune(body, i)
		n += if code >= 0x10000 { 2 } else { 1 }
		i += size
	}
	return n
}

// decode_rune returns the code point that starts at `body[i]`, and how many bytes
// encode it, or -1 and 1 for a byte that doesn't start valid UTF-8.
fn decode_rune(body string, i int) (int, int) {
	b := body[i]
	if b < 0x80 {
		return int(b), 1
	}
	mut size := 0
	mut code := 0
	if b & 0xe0 == 0xc0 {
		size = 2
		code = int(b & 0x1f)
	} else if b & 0xf0 == 0xe0 {
		size = 3
		code = int(b & 0x0f)
	} else if b & 0xf8 == 0xf0 {
		size = 4
		code = int(b & 0x07)
	} else {
		return -1, 1
	}
	if i + size > body.len {
		return -1, 1
	}
	for k in 1 .. size {
		c := body[i + k]
		if c & 0xc0 != 0x80 {
			return -1, 1
		}
		code = int((u32(code) << 6) | u32(c & 0x3f))
	}
	// reject overlong encodings and surrogates
	min := match size {
		2 { 0x80 }
		3 { 0x800 }
		else { 0x10000 }
	}
	if code < min || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) {
		return -1, 1
	}
	return code, size
}
