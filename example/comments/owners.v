module comments

import comments.models as comment_models

// Owner is a kind of record that comments can be on, such as an article. The
// app registers each kind with the `Service`, keyed by its `owner_type`, so
// this module doesn't depend on the modules that define them.
pub struct Owner {
pub:
	// id_of returns the id of the record with the slug `slug`, or a
	// `NotFoundError` when it is missing or deleted.
	id_of fn (slug string) !int @[required]
	// slugs_on returns the slugs of the records of this kind that the comments
	// in `list` are on, keyed by id, deleted ones included. It loads them with
	// one query, and none when no comment in `list` is on this kind.
	slugs_on fn (list []comment_models.Comment) !map[int]string @[required]
}
