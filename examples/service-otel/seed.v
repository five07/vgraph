module main

import time
import graph

// seed loads example data: two users, an article and a post by each, and
// comments on both kinds of record, one of them a reply. It does nothing when
// the database has any users, deleted ones included, so a database file is
// seeded once and an in-memory one on every start.
fn seed(g graph.Graph) ! {
	if g.skip('soft_delete').users().count()! > 0 {
		return
	}
	g.tx(fn (tx graph.Graph) ! {
		ada := tx.users().create().set_name('Ada Lovelace').set_email('ada@example.com').save()!
		grace := tx.users().create().set_name('Grace Hopper').set_email('grace@example.com').save()!
		engine := tx.articles().create().set_author(ada).set_title('Notes on the Analytical Engine').set_summary('What a general-purpose machine could do.').set_body('The engine might act upon other things besides number.').set_published_at(time.now()).save()!
		tx.articles().create().set_author(grace).set_title('Debugging, a draft').set_body('First actual case of bug being found.').exec()!
		tx.posts().create().set_author(ada).set_body('Trying out V today.').exec()!
		compiler := tx.posts().create().set_author(grace).set_body('Wrote a compiler this week.').save()!
		question := tx.comments().create().set_author(grace).set_article(engine).set_body('Could it compose music?').save()!
		tx.comments().create().set_author(ada).set_article(engine).set_parent(question).set_body('Elaborate pieces, of any degree of complexity.').exec()!
		tx.comments().create().set_author(ada).set_post(compiler).set_body('Congratulations!').exec()!
	})!
}
