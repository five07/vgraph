module app

// The errors below are the ones stores and handlers return for problems the
// client caused. `fail` turns each into a status code and a JSON body; it
// treats any other error as a server error, and doesn't show its text.

// NotFoundError reports that a record does not exist, or is deleted.
pub struct NotFoundError {
	Error
pub:
	message string
}

// msg returns the message of the error.
pub fn (e NotFoundError) msg() string {
	return e.message
}

// ValidationError reports a request body that is malformed or breaks a rule.
pub struct ValidationError {
	Error
pub:
	message string
}

// msg returns the message of the error.
pub fn (e ValidationError) msg() string {
	return e.message
}

// BadReferenceError reports a request body that refers to a record that does
// not exist, or is deleted.
pub struct BadReferenceError {
	Error
pub:
	message string
}

// msg returns the message of the error.
pub fn (e BadReferenceError) msg() string {
	return e.message
}

// ConflictError reports a write that clashes with another record, such as a
// duplicate email.
pub struct ConflictError {
	Error
pub:
	message string
}

// msg returns the message of the error.
pub fn (e ConflictError) msg() string {
	return e.message
}
