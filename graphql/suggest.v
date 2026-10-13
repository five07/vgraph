module graphql

// The helpers behind "Did you mean ...?" in messages, as graphql-js writes them.

const max_suggestions = 5

// did_you_mean returns ` Did you mean "a", "b", or "c"?` for `suggestions`, or
// '' when there are none. `sub_message` goes after "Did you mean".
fn did_you_mean(sub_message string, suggestions []string) string {
	if suggestions.len == 0 {
		return ''
	}
	mut message := ' Did you mean '
	if sub_message != '' {
		message += sub_message + ' '
	}
	quoted := suggestions.map('"${it}"')
	if quoted.len == 1 {
		return message + quoted[0] + '?'
	}
	if quoted.len == 2 {
		return message + quoted[0] + ' or ' + quoted[1] + '?'
	}
	mut selected := quoted#[..max_suggestions].clone()
	last := selected.pop()
	return message + selected.join(', ') + ', or ' + last + '?'
}

// suggestion_list returns the options close enough to `input` to suggest,
// closest first.
fn suggestion_list(input string, options []string) []string {
	mut by_distance := map[string]int{}
	mut order := []string{}
	threshold := int(f64(input.len) * 0.4) + 1
	input_lower := input.to_lower()
	for option in options {
		distance := lexical_distance(input, input_lower, option, threshold) or { continue }
		if option !in by_distance {
			order << option
		}
		by_distance[option] = distance
	}
	order.sort_with_compare(fn [by_distance] (a &string, b &string) int {
		diff := by_distance[*a] - by_distance[*b]
		return if diff != 0 { diff } else { natural_compare(*a, *b) }
	})
	return order
}

// lexical_distance is the Damerau-Levenshtein distance between `input` and
// `option`, ignoring case, as graphql-js measures it, or `none` past `threshold`.
fn lexical_distance(input string, input_lower string, option string, threshold int) ?int {
	if input == option {
		return 0
	}
	option_lower := option.to_lower()
	if input_lower == option_lower {
		return 1
	}
	longer, shorter := if option_lower.len < input_lower.len {
		input_lower, option_lower
	} else {
		option_lower, input_lower
	}
	a := longer.bytes()
	b := shorter.bytes()
	if a.len - b.len > threshold {
		return none
	}
	mut rows := [][]int{len: 3, init: []int{len: b.len + 1}}
	for j in 0 .. b.len + 1 {
		rows[0][j] = j
	}
	for i in 1 .. a.len + 1 {
		up := (i - 1) % 3
		cur := i % 3
		rows[cur][0] = i
		mut smallest := i
		for j in 1 .. b.len + 1 {
			cost := if a[i - 1] == b[j - 1] { 0 } else { 1 }
			mut cell := min3(rows[up][j] + 1, rows[cur][j - 1] + 1, rows[up][j - 1] + cost)
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				double_diagonal := rows[(i - 2) % 3][j - 2]
				if double_diagonal + 1 < cell {
					cell = double_diagonal + 1
				}
			}
			if cell < smallest {
				smallest = cell
			}
			rows[cur][j] = cell
		}
		if smallest > threshold {
			return none
		}
	}
	distance := rows[a.len % 3][b.len]
	return if distance <= threshold { distance } else { none }
}

fn min3(a int, b int, c int) int {
	mut m := if a < b { a } else { b }
	return if c < m { c } else { m }
}

// natural_compare compares strings with runs of digits compared as numbers.
fn natural_compare(a string, b string) int {
	mut ai := 0
	mut bi := 0
	for ai < a.len && bi < b.len {
		mut ac := a[ai]
		mut bc := b[bi]
		if ac.is_digit() && bc.is_digit() {
			mut an := 0
			for {
				ai++
				an = an * 10 + int(ac - `0`)
				if ai >= a.len {
					break
				}
				ac = a[ai]
				if !(ac.is_digit() && an > 0) {
					break
				}
			}
			mut bn := 0
			for {
				bi++
				bn = bn * 10 + int(bc - `0`)
				if bi >= b.len {
					break
				}
				bc = b[bi]
				if !(bc.is_digit() && bn > 0) {
					break
				}
			}
			if an < bn {
				return -1
			}
			if an > bn {
				return 1
			}
		} else {
			if ac < bc {
				return -1
			}
			if ac > bc {
				return 1
			}
			ai++
			bi++
		}
	}
	return a.len - b.len
}
