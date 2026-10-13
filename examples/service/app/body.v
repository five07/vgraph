module app

import json2
import log

// ignored_keys are the keys a request body may contain without being fields of
// its input: the server-owned fields of a record, which clients often send
// back from a response. They are dropped, never written.
pub const ignored_keys = ['slug', 'created_at', 'updated_at']!

// decode_body decodes the JSON request body into a `T`. The body must be a
// JSON object whose keys are all fields of `T`, apart from `ignored_keys`; any
// other key is reported as not supported. A body that isn't valid JSON for `T`
// gives a fixed message: the decoder's own message quotes the body and
// contains terminal color codes.
pub fn decode_body[T](ctx &Context) !T {
	mut fields := []string{}
	$for field in T.fields {
		fields << field.name
	}
	check_keys(ctx.req.data, fields)!
	return json2.decode[T](ctx.req.data) or {
		log.debug('invalid JSON body: ${err}')
		return invalid_body()
	}
}

// check_keys checks that `body` is a JSON object, and that each of its keys is
// one of `fields` or of `ignored_keys`.
fn check_keys(body string, fields []string) ! {
	value := json2.decode[json2.Any](body) or { return invalid_body() }
	if value !is map[string]json2.Any {
		return invalid_body()
	}
	mut unsupported := []string{}
	for key, _ in value.as_map() {
		if key !in fields && key !in ignored_keys {
			unsupported << key
		}
	}
	if unsupported.len > 0 {
		unsupported.sort()
		return ValidationError{
			message: 'The following attribute(s) are not supported: [${unsupported.join(', ')}]'
		}
	}
}

fn invalid_body() IError {
	return ValidationError{
		message: 'invalid JSON body'
	}
}
