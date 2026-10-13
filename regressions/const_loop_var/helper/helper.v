module helper

pub fn count() int {
	mut total := 0
	for usage in [1, 2] {
		total += usage
	}
	return total
}
