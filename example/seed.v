module main

import articles.models as article_models
import comments.models as comment_models
import posts.models as post_models
import users.models as user_models

// seed loads example data: two users, an article and a post by each, and
// comments on both kinds of record, one of them a reply. It does nothing when
// the database has any users, deleted ones included, so a database file is
// seeded once and an in-memory one on every start.
fn seed(users user_models.UserStore, articles article_models.ArticleStore, posts post_models.PostStore, comments comment_models.CommentStore) ! {
	if users.count_all()! > 0 {
		return
	}
	ada := users.insert(name: 'Ada Lovelace', email: 'ada@example.com')!
	grace := users.insert(name: 'Grace Hopper', email: 'grace@example.com')!

	engine := articles.insert(ada.id,
		title:     'Notes on the Analytical Engine'
		summary:   'What a general-purpose machine could do.'
		body:      'The engine might act upon other things besides number.'
		published: true
	)!
	articles.insert(grace.id,
		title: 'Debugging, a draft'
		body:  'First actual case of bug being found.'
	)!
	posts.insert(ada.id, body: 'Trying out V today.')!
	compiler := posts.insert(grace.id, body: 'Wrote a compiler this week.')!

	article_type := comment_models.owner_type[article_models.Article]()
	question := comments.insert(
		user_id:    grace.id
		owner_type: article_type
		owner_id:   engine.id
		body:       'Could it compose music?'
	)!
	comments.insert(
		user_id:     ada.id
		owner_type:  article_type
		owner_id:    engine.id
		parent_slug: question.slug
		body:        'Elaborate pieces, of any degree of complexity.'
	)!
	comments.insert(
		user_id:    ada.id
		owner_type: comment_models.owner_type[post_models.Post]()
		owner_id:   compiler.id
		body:       'Congratulations!'
	)!
}
