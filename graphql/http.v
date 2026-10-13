module graphql

import net.urllib

// HttpRequest is the part of an HTTP request the handler needs, so any web
// framework can call it.
pub struct HttpRequest {
pub:
	method       string // GET or POST
	content_type string
	accept       string
	query_string string // the URL's query, for GET: `query=...&variables=...`
	body         string
}

// HttpResponse is the handler's answer. `headers` holds any extra header, such
// as `Allow` for a 405.
pub struct HttpResponse {
pub:
	status       int
	content_type string
	body         string
	headers      map[string]string
}

const graphql_response_json = 'application/graphql-response+json; charset=utf-8'
const plain_json = 'application/json; charset=utf-8'

// handle answers a GraphQL request over HTTP, as the GraphQL over HTTP spec
// describes: POST with a JSON body, or GET with the request in the URL's query
// (queries only). A client that accepts `application/graphql-response+json`
// gets that media type, and status 400 for a request that couldn't run;
// otherwise the response is `application/json` with status 200.
pub fn (s &Server) handle(req HttpRequest, ctx Context) HttpResponse {
	modern := req.accept.contains('application/graphql-response+json')
	content_type := if modern { graphql_response_json } else { plain_json }
	mut params := map[string]Value{}
	match req.method.to_upper() {
		'POST' {
			media := req.content_type.all_before(';').trim_space().to_lower()
			if media != 'application/json' && media != 'application/graphql+json' {
				return bad_request(415, content_type, 'Content-Type must be application/json.')
			}
			body := parse_json(req.body) or {
				return bad_request(400, content_type, 'The body is not valid JSON: ${err.msg()}')
			}
			if body !is map[string]Value {
				return bad_request(400, content_type, 'The body must be a JSON object.')
			}
			params = (body as map[string]Value).clone()
		}
		'GET' {
			values := urllib.parse_query(req.query_string) or {
				return bad_request(400, content_type, 'The query string is malformed.')
			}
			for key in ['query', 'operationName'] {
				if v := values.get(key) {
					params[key] = v
				}
			}
			if v := values.get('variables') {
				params['variables'] = parse_json(v) or {
					return bad_request(400, content_type, 'variables is not valid JSON.')
				}
			}
		}
		else {
			return HttpResponse{
				status:       405
				content_type: content_type
				body:         error_body('GraphQL is served with GET and POST.')
				headers:      {
					'Allow': 'GET, POST'
				}
			}
		}
	}
	query := params['query'] or { null }
	if query !is string {
		return bad_request(400, content_type, 'The request must have a "query" string.')
	}
	operation_name := params['operationName'] or { null }
	if operation_name !is string && operation_name !is Null {
		return bad_request(400, content_type, '"operationName" must be a string.')
	}
	variables := params['variables'] or { null }
	if variables !is map[string]Value && variables !is Null {
		return bad_request(400, content_type, '"variables" must be an object.')
	}
	request := Request{
		query:          query as string
		operation_name: if operation_name is string { operation_name } else { '' }
		variables:      if variables is map[string]Value {
			variables.clone()
		} else {
			map[string]Value{}
		}
	}
	if req.method.to_upper() == 'GET' {
		// GET is for queries: a mutation must come by POST
		if doc := parse(request.query, s.parse_options) {
			if op := operation_of(&doc, request.operation_name) {
				if op.operation != .query {
					return HttpResponse{
						status:       405
						content_type: content_type
						body:         error_body('Only queries can be sent with GET; use POST for a ${op.operation}.')
						headers:      {
							'Allow': 'POST'
						}
					}
				}
			}
		}
	}
	response := s.execute(request, ctx)
	status := if modern && response.request_error { 400 } else { 200 }
	return HttpResponse{
		status:       status
		content_type: content_type
		body:         response.json()
	}
}

fn error_body(message string) string {
	return Response{
		errors: [GraphQLError{
			message: message
		}]
	}.json()
}

fn bad_request(status int, content_type string, message string) HttpResponse {
	return HttpResponse{
		status:       status
		content_type: content_type
		body:         error_body(message)
	}
}
