module app

import json2
import net.http
import veb

// ErrorBody is the JSON body of an error response outside GraphQL.
pub struct ErrorBody {
pub:
	error string
}

// render writes `data` as the JSON response, with the status `status`.
pub fn render[T](mut ctx Context, status http.Status, data T) veb.Result {
	ctx.res.set_status(status)
	return ctx.send_response_to_client('application/json', json2.encode(data))
}

// render_error writes `{"error": message}` with the status `status`.
pub fn render_error(mut ctx Context, status http.Status, message string) veb.Result {
	return render(mut ctx, status, ErrorBody{ error: message })
}
