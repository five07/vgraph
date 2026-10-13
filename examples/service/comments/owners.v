module comments

// Owner is a kind of record that comments can be on, such as an article. The
// app registers each kind with the `Service`, keyed by its `owner_type`, so
// this module doesn't depend on their stores. Loading owners goes through the
// comment's `article` and `post` edges instead.
pub struct Owner {
pub:
	// id_of returns the id of the record with the slug `slug`, or a
	// `NotFoundError` when it is missing or deleted.
	id_of fn (slug string) !int @[required]
}
