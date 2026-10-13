module app

import uuid

// new_slug returns a new record slug: a UUID v7, which is time-ordered, so new
// slugs land at the end of the slug index.
pub fn new_slug() string {
	return uuid.new_v7().str()
}

// valid_slug reports whether `s` is a slug in its canonical form, lowercase
// with dashes, as `new_slug` makes them.
pub fn valid_slug(s string) bool {
	u := uuid.parse(s) or { return false }
	return u.str() == s
}
