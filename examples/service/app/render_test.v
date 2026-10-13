module app

fn test_status_of() {
	cases := {
		'not found':  IError(NotFoundError{
			message: 'no such article'
		})
		'validation': IError(ValidationError{
			message: 'a title is required'
		})
		'reference':  IError(BadReferenceError{
			message: 'no such user'
		})
		'conflict':   IError(ConflictError{
			message: 'email taken'
		})
		'other':      error('UNIQUE constraint failed (INSERT INTO users ...)')
	}
	mut got := map[string]string{}
	for name, err in cases {
		status, message := status_of(err)
		got[name] = '${status.int()} ${message}'
	}
	assert got == {
		'not found':  '404 no such article'
		'validation': '400 a title is required'
		'reference':  '400 no such user'
		'conflict':   '409 email taken'
		'other':      '500 internal error'
	}
}
