module app

import json2
import log
import net.http
import veb

// ErrorBody is the JSON body of every error response.
pub struct ErrorBody {
pub:
	error string
}

// render writes `data` as the response, with the status `status`. Every
// response with a body goes through here, so another output format, such as
// protobuf, can be added in one place.
pub fn render[T](mut ctx Context, status http.Status, data T) veb.Result {
	ctx.res.set_status(status)
	return ctx.send_response_to_client('application/json', json2.encode(data))
}

// render_error writes `{"error": message}` with the status `status`.
pub fn render_error(mut ctx Context, status http.Status, message string) veb.Result {
	return render(mut ctx, status, ErrorBody{ error: message })
}

// fail writes the error `err`, with the status its type stands for. An error
// of any other type is logged and reported as a server error, without its
// text, which can contain SQL.
pub fn fail(mut ctx Context, err IError) veb.Result {
	status, message := status_of(err)
	if status == .internal_server_error {
		log.error('${ctx.req.method} ${ctx.req.url}: ${err}')
	}
	return render_error(mut ctx, status, message)
}

// client_message returns the message a client may see for `err`: its own for
// the app's errors, and `internal error` for any other, whose text can contain
// SQL. GraphQL errors use it.
pub fn client_message(err IError) string {
	status, message := status_of(err)
	if status == .internal_server_error {
		log.error('graphql: ${err}')
	}
	return message
}

// status_of returns the status code and the client-facing message for `err`.
fn status_of(err IError) (http.Status, string) {
	return match err {
		NotFoundError { http.Status.not_found, err.message }
		ValidationError { http.Status.bad_request, err.message }
		BadReferenceError { http.Status.bad_request, err.message }
		ConflictError { http.Status.conflict, err.message }
		else { http.Status.internal_server_error, 'internal error' }
	}
}
