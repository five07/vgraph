module app

import veb

// Context is the request context shared by the app and every feature's routes.
pub struct Context {
	veb.Context
}

// not_found answers a request that matched no route. It replaces veb's
// plain-text 404, so every response of the API is JSON.
pub fn (mut ctx Context) not_found() veb.Result {
	return render_error(mut ctx, .not_found, 'not found')
}
