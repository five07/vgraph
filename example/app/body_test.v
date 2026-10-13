module app

fn message(body string) string {
	check_keys(body, ['name', 'email']) or { return err.msg() }
	return 'ok'
}

fn test_check_keys() {
	assert message('{"name":"a","email":"b"}') == 'ok'
	assert message('{}') == 'ok'
	assert message('{"name":"a","slug":"x","created_at":"y","updated_at":"z"}') == 'ok'
	assert message('{"name":"a","id":1,"admin":true}') == 'The following attribute(s) are not supported: [admin, id]'
	assert message('{"nested":{"name":"a"}}') == 'The following attribute(s) are not supported: [nested]'
}

fn test_check_keys_needs_a_json_object() {
	for body in ['', 'nope', '[]', '"a"', '1', 'null', '{"name":'] {
		assert message(body) == 'invalid JSON body', body
	}
}
