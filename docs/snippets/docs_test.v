module main

// Checks that the code in the guides (`docs/*.md`) and the README is the code
// here, which compiles and runs. A fenced block preceded by
// `<!-- snippet: <path>#<name> -->` must equal the region of `<path>` (from
// the repository's root) between `// snippet: <name>` and `// end snippet`,
// without its common indentation; `<path>` alone is the whole file. Every
// ```v block needs one. `UPDATE_SNIPPETS=1 v test docs_test.v` rewrites the
// blocks from the code instead of checking them.
import os

const root = os.real_path(os.join_path(@DIR, '..', '..'))

const marker = '<!-- snippet: '

// region returns the code of the snippet `name` in the file `path`, or the
// whole file when `name` is empty.
fn region(path string, name string) !string {
	text := os.read_file(os.join_path(root, path)) or { return error('${path}: ${err.msg()}') }
	if name == '' {
		return text.trim_right('\n')
	}
	mut lines := []string{}
	mut inside := false
	for line in text.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed == '// snippet: ${name}' {
			if inside {
				return error('${path}: `${name}` starts twice')
			}
			inside = true
			continue
		}
		if inside && trimmed == '// end snippet' {
			return dedent(lines).join('\n').trim_right('\n')
		}
		if inside {
			lines << line
		}
	}
	return error('${path}: no snippet `${name}`')
}

// dedent removes the indentation that every line of `lines` that isn't blank
// starts with.
fn dedent(lines []string) []string {
	mut common := -1
	for line in lines {
		if line.trim_space() == '' {
			continue
		}
		n := line.len - line.trim_left('\t').len
		if common < 0 || n < common {
			common = n
		}
	}
	if common <= 0 {
		return lines
	}
	return lines.map(if it.trim_space() == '' { '' } else { it[common..] })
}

// Block is a fenced code block of a Markdown file.
struct Block {
	file   string
	line   int // the line of its opening fence, from 1
	lang   string
	source string // the marker's `<path>#<name>`, or ''
	start  int    // the index of its first line of code
	end    int    // the index of its closing fence
}

fn blocks(file string, lines []string) ![]Block {
	mut out := []Block{}
	mut i := 0
	for i < lines.len {
		line := lines[i]
		if !line.starts_with('```') || line.trim_space() == '```' {
			i++
			continue
		}
		lang := line[3..].trim_space()
		mut source := ''
		if i > 0 && lines[i - 1].starts_with(marker) {
			source = lines[i - 1].all_after(marker).all_before(' -->').trim_space()
		}
		mut end := i + 1
		for end < lines.len && lines[end].trim_space() != '```' {
			end++
		}
		if end == lines.len {
			return error('${file}:${i + 1}: a code block never ends')
		}
		out << Block{
			file:   file
			line:   i + 1
			lang:   lang
			source: source
			start:  i + 1
			end:    end
		}
		i = end + 1
	}
	return out
}

fn markdown_files() []string {
	mut files := ['README.md']
	for f in os.ls(os.join_path(root, 'docs')) or { []string{} } {
		if f.ends_with('.md') {
			files << os.join_path('docs', f)
		}
	}
	files.sort()
	return files
}

fn test_the_docs_show_the_code_that_runs() {
	update := os.getenv('UPDATE_SNIPPETS') == '1'
	mut problems := []string{}
	mut checked := 0
	for file in markdown_files() {
		path := os.join_path(root, file)
		mut lines := os.read_lines(path)!
		mut changed := false
		// from the end, so that a rewrite doesn't move the blocks before it
		for b in blocks(file, lines)!.reverse() {
			if b.source == '' {
				if b.lang == 'v' {
					problems << '${file}:${b.line}: a ```v block needs a `${marker}<path>#<name> -->` line before it'
				}
				continue
			}
			want := region(b.source.all_before('#'), if b.source.contains('#') {
				b.source.all_after('#')
			} else {
				''
			})!
			got := lines[b.start..b.end].join('\n')
			checked++
			if got == want {
				continue
			}
			if update {
				mut next := lines[..b.start].clone()
				next << want.split('\n')
				next << lines[b.end..]
				lines = next.clone()
				changed = true
			} else {
				problems << '${file}:${b.line}: differs from ${b.source}; run `UPDATE_SNIPPETS=1 v test docs/snippets/docs_test.v`'
			}
		}
		if changed {
			os.write_file(path, lines.join('\n') + '\n')!
		}
	}
	assert problems.len == 0, problems.join('\n')
	assert checked > 0
}

fn test_dedent() {
	assert dedent(['\t\ta', '', '\t\t\tb']) == ['a', '', '\tb']
}
