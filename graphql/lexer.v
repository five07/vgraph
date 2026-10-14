module graphql

import strings

// TokenKind is the kind of a lexical token.
pub enum TokenKind {
	sof
	eof
	bang
	dollar
	amp
	paren_l
	paren_r
	dot
	spread
	colon
	equals
	at
	bracket_l
	bracket_r
	brace_l
	pipe
	brace_r
	name
	int
	float
	string
	block_string
	comment
}

// desc returns the kind as graphql-js names it in messages: `<EOF>`, `Name`, or
// a punctuator such as `{`.
pub fn (k TokenKind) desc() string {
	return match k {
		.sof { '<SOF>' }
		.eof { '<EOF>' }
		.bang { '!' }
		.dollar { '$' }
		.amp { '&' }
		.paren_l { '(' }
		.paren_r { ')' }
		.dot { '.' }
		.spread { '...' }
		.colon { ':' }
		.equals { '=' }
		.at { '@' }
		.bracket_l { '[' }
		.bracket_r { ']' }
		.brace_l { '{' }
		.pipe { '|' }
		.brace_r { '}' }
		.name { 'Name' }
		.int { 'Int' }
		.float { 'Float' }
		.string { 'String' }
		.block_string { 'BlockString' }
		.comment { 'Comment' }
	}
}

fn (k TokenKind) is_punctuator() bool {
	return k in [.bang, .dollar, .amp, .paren_l, .paren_r, .dot, .spread, .colon, .equals, .at,
		.bracket_l, .bracket_r, .brace_l, .pipe, .brace_r]
}

fn (k TokenKind) has_value() bool {
	return k in [.name, .int, .float, .string, .block_string, .comment]
}

// Token is a lexical token: its kind, where it is (byte offsets, and the line and
// column it starts at), and the value of a name, number, string or comment.
pub struct Token {
pub:
	kind   TokenKind
	start  int
	end    int
	line   int
	column int
	value  string
}

// desc returns the token as messages name it, such as `Name "foo"`.
fn (t Token) desc() string {
	kind := if t.kind.is_punctuator() { '"${t.kind.desc()}"' } else { t.kind.desc() }
	return if t.kind.has_value() { '${kind} "${t.value}"' } else { kind }
}

// Lexer reads the tokens of a source one at a time, skipping comments.
pub struct Lexer {
pub:
	body string
pub mut:
	token      Token // the current token
	last_token Token // the token before it
mut:
	line       int = 1
	line_start int
	next       ?Token
}

// Lexer.new returns a lexer positioned at the start of `body`.
pub fn Lexer.new(body string) Lexer {
	return Lexer{
		body:  body
		token: Token{
			kind:   .sof
			line:   0
			column: 0
		}
	}
}

// advance moves to the next token, and returns it.
pub fn (mut l Lexer) advance() !Token {
	l.last_token = l.token
	l.token = l.lookahead()!
	l.next = none
	return l.token
}

// lookahead returns the token after the current one, without moving to it.
pub fn (mut l Lexer) lookahead() !Token {
	if next := l.next {
		return next
	}
	mut token := l.token
	if token.kind != .eof {
		for {
			token = l.read_token(token.end)!
			if token.kind != .comment {
				break
			}
		}
	}
	l.next = token
	return token
}

fn (l &Lexer) make(kind TokenKind, start int, end int, value string) Token {
	return Token{
		kind:   kind
		start:  start
		end:    end
		line:   l.line
		column: 1 + utf16_len(l.body, l.line_start, start)
		value:  value
	}
}

fn (l &Lexer) error(pos int, description string) GraphQLError {
	return syntax_error(l.body, pos, description)
}

fn (l &Lexer) code_at(pos int) int {
	if pos >= l.body.len || pos < 0 {
		return -1
	}
	return int(l.body[pos])
}

// print_code_point_at names the character at `pos` for a message: printable
// ASCII in quotes, anything else as `U+XXXX`, and `<EOF>` past the end.
fn (l &Lexer) print_code_point_at(pos int) string {
	if pos >= l.body.len {
		return '<EOF>'
	}
	code, _ := decode_rune(l.body, pos)
	if code >= 0x20 && code <= 0x7e {
		c := u8(code).ascii_str()
		return if c == '"' { '\'"\'' } else { '"${c}"' }
	}
	if code < 0 {
		return 'U+FFFD'
	}
	return 'U+' + '${code:04X}'
}

fn (mut l Lexer) read_token(start int) !Token {
	body := l.body
	mut pos := start
	for pos < body.len {
		c := body[pos]
		match c {
			`\t`, ` `, `,` {
				pos++
				continue
			}
			`\n` {
				pos++
				l.line++
				l.line_start = pos
				continue
			}
			`\r` {
				pos += if l.code_at(pos + 1) == `\n` { 2 } else { 1 }
				l.line++
				l.line_start = pos
				continue
			}
			0xef {
				// the byte order mark, U+FEFF
				if pos + 2 < body.len && body[pos + 1] == 0xbb && body[pos + 2] == 0xbf {
					pos += 3
					continue
				}
			}
			`#` {
				return l.read_comment(pos)
			}
			`!` {
				return l.make(.bang, pos, pos + 1, '')
			}
			`$` {
				return l.make(.dollar, pos, pos + 1, '')
			}
			`&` {
				return l.make(.amp, pos, pos + 1, '')
			}
			`(` {
				return l.make(.paren_l, pos, pos + 1, '')
			}
			`)` {
				return l.make(.paren_r, pos, pos + 1, '')
			}
			`.` {
				if l.code_at(pos + 1) == `.` && l.code_at(pos + 2) == `.` {
					return l.make(.spread, pos, pos + 3, '')
				}
			}
			`:` {
				return l.make(.colon, pos, pos + 1, '')
			}
			`=` {
				return l.make(.equals, pos, pos + 1, '')
			}
			`@` {
				return l.make(.at, pos, pos + 1, '')
			}
			`[` {
				return l.make(.bracket_l, pos, pos + 1, '')
			}
			`]` {
				return l.make(.bracket_r, pos, pos + 1, '')
			}
			`{` {
				return l.make(.brace_l, pos, pos + 1, '')
			}
			`|` {
				return l.make(.pipe, pos, pos + 1, '')
			}
			`}` {
				return l.make(.brace_r, pos, pos + 1, '')
			}
			`"` {
				if l.code_at(pos + 1) == `"` && l.code_at(pos + 2) == `"` {
					return l.read_block_string(pos)
				}
				return l.read_string(pos)
			}
			else {}
		}
		if c.is_digit() || c == `-` {
			return l.read_number(pos)
		}
		if is_name_start(c) {
			return l.read_name(pos)
		}
		if c == `'` {
			return l.error(pos, 'Unexpected single quote character (\'), did you mean to use a double quote (")?')
		}
		code, _ := decode_rune(body, pos)
		if code < 0 {
			return l.error(pos, 'Invalid character: ${l.print_code_point_at(pos)}.')
		}
		return l.error(pos, 'Unexpected character: ${l.print_code_point_at(pos)}.')
	}
	return l.make(.eof, body.len, body.len, '')
}

fn is_name_start(c u8) bool {
	return c.is_letter() || c == `_`
}

fn is_name_continue(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

fn (l &Lexer) read_comment(start int) !Token {
	mut pos := start + 1
	for pos < l.body.len {
		c := l.body[pos]
		if c == `\n` || c == `\r` {
			break
		}
		code, size := decode_rune(l.body, pos)
		if code < 0 {
			break
		}
		pos += size
	}
	return l.make(.comment, start, pos, l.body[start + 1..pos])
}

fn (l &Lexer) read_name(start int) !Token {
	mut pos := start + 1
	for pos < l.body.len && is_name_continue(l.body[pos]) {
		pos++
	}
	return l.make(.name, start, pos, l.body[start..pos])
}

fn (l &Lexer) read_number(start int) !Token {
	mut pos := start
	mut code := l.code_at(pos)
	mut is_float := false
	if code == `-` {
		pos++
		code = l.code_at(pos)
	}
	if code == `0` {
		pos++
		code = l.code_at(pos)
		if is_digit_code(code) {
			return l.error(pos, 'Invalid number, unexpected digit after 0: ${l.print_code_point_at(pos)}.')
		}
	} else {
		pos = l.read_digits(pos)!
		code = l.code_at(pos)
	}
	if code == `.` {
		is_float = true
		pos++
		pos = l.read_digits(pos)!
		code = l.code_at(pos)
	}
	if code == `E` || code == `e` {
		is_float = true
		pos++
		code = l.code_at(pos)
		if code == `+` || code == `-` {
			pos++
		}
		pos = l.read_digits(pos)!
		code = l.code_at(pos)
	}
	if code == `.` || (code >= 0 && is_name_start(u8(code))) {
		return l.error(pos, 'Invalid number, expected digit but got: ${l.print_code_point_at(pos)}.')
	}
	return l.make(if is_float { .float } else { .int }, start, pos, l.body[start..pos])
}

fn is_digit_code(code int) bool {
	return code >= `0` && code <= `9`
}

fn (l &Lexer) read_digits(start int) !int {
	if !is_digit_code(l.code_at(start)) {
		return l.error(start, 'Invalid number, expected digit but got: ${l.print_code_point_at(start)}.')
	}
	mut pos := start + 1
	for is_digit_code(l.code_at(pos)) {
		pos++
	}
	return pos
}

fn (l &Lexer) read_string(start int) !Token {
	body := l.body
	mut pos := start + 1
	mut chunk_start := pos
	mut value := strings.new_builder(16)
	for pos < body.len {
		c := body[pos]
		if c == `"` {
			value.write_string(body[chunk_start..pos])
			return l.make(.string, start, pos + 1, value.str())
		}
		if c == `\\` {
			value.write_string(body[chunk_start..pos])
			escaped, size := if l.code_at(pos + 1) == `u` {
				if l.code_at(pos + 2) == `{` {
					l.read_unicode_variable(pos)!
				} else {
					l.read_unicode_fixed(pos)!
				}
			} else {
				l.read_escaped_character(pos)!
			}
			value.write_string(escaped)
			pos += size
			chunk_start = pos
			continue
		}
		if c == `\n` || c == `\r` {
			break
		}
		code, size := decode_rune(body, pos)
		if code < 0 {
			return l.error(pos, 'Invalid character within String: ${l.print_code_point_at(pos)}.')
		}
		pos += size
	}
	return l.error(pos, 'Unterminated string.')
}

fn (l &Lexer) read_unicode_variable(pos int) !(string, int) {
	mut point := 0
	mut size := 3
	for size < 12 {
		code := l.code_at(pos + size)
		size++
		if code == `}` {
			if size < 5 || !is_scalar_value(point) {
				break
			}
			return rune(point).str(), size
		}
		digit := hex_digit(code)
		if digit < 0 {
			break
		}
		// as graphql-js does in 32-bit arithmetic: stop once the sign bit is set
		shifted := (u32(point) << 4) | u32(digit)
		if shifted & 0x8000_0000 != 0 {
			break
		}
		point = int(shifted)
	}
	end := if pos + size < l.body.len { pos + size } else { l.body.len }
	return l.error(pos, 'Invalid Unicode escape sequence: "${l.body[pos..end]}".')
}

fn (l &Lexer) read_unicode_fixed(pos int) !(string, int) {
	code := l.read_hex4(pos + 2)
	if code >= 0 && is_scalar_value(code) {
		return rune(code).str(), 6
	}
	// a JSON-style surrogate pair: allowed only when a valid pair is formed
	if code >= 0xd800 && code <= 0xdbff && l.code_at(pos + 6) == `\\`
		&& l.code_at(pos + 7) == `u` {
		trailing := l.read_hex4(pos + 8)
		if trailing >= 0xdc00 && trailing <= 0xdfff {
			point := 0x10000 + ((code - 0xd800) << 10) + (trailing - 0xdc00)
			return rune(point).str(), 12
		}
	}
	end := if pos + 6 < l.body.len { pos + 6 } else { l.body.len }
	return l.error(pos, 'Invalid Unicode escape sequence: "${l.body[pos..end]}".')
}

fn (l &Lexer) read_hex4(pos int) int {
	mut code := 0
	for k in 0 .. 4 {
		digit := hex_digit(l.code_at(pos + k))
		if digit < 0 {
			return -1
		}
		code = int((u32(code) << 4) | u32(digit))
	}
	return code
}

fn hex_digit(code int) int {
	return if code >= `0` && code <= `9` {
		code - `0`
	} else if code >= `A` && code <= `F` {
		code - `A` + 10
	} else if code >= `a` && code <= `f` {
		code - `a` + 10
	} else {
		-1
	}
}

fn is_scalar_value(code int) bool {
	return (code >= 0 && code <= 0xd7ff) || (code >= 0xe000 && code <= 0x10ffff)
}

fn (l &Lexer) read_escaped_character(pos int) !(string, int) {
	value := match l.code_at(pos + 1) {
		`"` { '"' }
		`\\` { '\\' }
		`/` { '/' }
		`b` { '\b' }
		`f` { '\f' }
		`n` { '\n' }
		`r` { '\r' }
		`t` { '\t' }
		else { '' }
	}
	if value != '' {
		return value, 2
	}
	end := if pos + 2 < l.body.len { pos + 2 } else { l.body.len }
	// a multi-byte character after the backslash is printed whole
	mut stop := end
	if pos + 1 < l.body.len && l.body[pos + 1] >= 0x80 {
		_, size := decode_rune(l.body, pos + 1)
		stop = pos + 1 + size
	}
	return l.error(pos, 'Invalid character escape sequence: "${l.body[pos..stop]}".')
}

fn (mut l Lexer) read_block_string(start int) !Token {
	body := l.body
	mut line_start := l.line_start
	mut pos := start + 3
	mut chunk_start := pos
	mut current := strings.new_builder(16)
	mut lines := []string{}
	for pos < body.len {
		c := body[pos]
		if c == `"` && l.code_at(pos + 1) == `"` && l.code_at(pos + 2) == `"` {
			current.write_string(body[chunk_start..pos])
			lines << current.str()
			token := l.make(.block_string, start, pos + 3, dedent_block_string_lines(lines).join('\n'))
			l.line += lines.len - 1
			l.line_start = line_start
			return token
		}
		if c == `\\` && l.code_at(pos + 1) == `"` && l.code_at(pos + 2) == `"`
			&& l.code_at(pos + 3) == `"` {
			current.write_string(body[chunk_start..pos])
			chunk_start = pos + 1
			pos += 4
			continue
		}
		if c == `\n` || c == `\r` {
			current.write_string(body[chunk_start..pos])
			lines << current.str()
			pos += if c == `\r` && l.code_at(pos + 1) == `\n` { 2 } else { 1 }
			chunk_start = pos
			line_start = pos
			continue
		}
		code, size := decode_rune(body, pos)
		if code < 0 {
			return l.error(pos, 'Invalid character within String: ${l.print_code_point_at(pos)}.')
		}
		pos += size
	}
	return l.error(pos, 'Unterminated string.')
}

// dedent_block_string_lines removes the common indentation of a block string's
// lines after the first, and its leading and trailing blank lines.
pub fn dedent_block_string_lines(lines []string) []string {
	mut common := max_int
	mut first_non_empty := -1
	mut last_non_empty := -1
	for i, line in lines {
		ws := leading_whitespace(line)
		if ws == line.len {
			continue
		}
		if first_non_empty < 0 {
			first_non_empty = i
		}
		last_non_empty = i
		if i != 0 && ws < common {
			common = ws
		}
	}
	mut out := []string{}
	start := if first_non_empty < 0 { 0 } else { first_non_empty }
	for i in start .. last_non_empty + 1 {
		line := lines[i]
		out << if i == 0 || common == max_int {
			line
		} else if common >= line.len {
			''
		} else {
			line[common..]
		}
	}
	return out
}

fn leading_whitespace(s string) int {
	mut i := 0
	for i < s.len && (s[i] == ` ` || s[i] == `\t`) {
		i++
	}
	return i
}
