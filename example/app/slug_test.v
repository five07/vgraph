module app

fn test_new_slug_is_valid_and_unique() {
	a := new_slug()
	b := new_slug()
	assert valid_slug(a)
	assert a != b
	assert a.len == 36
}

fn test_valid_slug_rejects_other_forms() {
	s := new_slug()
	assert !valid_slug('')
	assert !valid_slug('nope')
	assert !valid_slug(s.to_upper())
	assert !valid_slug(s.replace('-', ''))
	assert !valid_slug('../${s}')
}
