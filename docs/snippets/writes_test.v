module main

import five07.vgraph
import graph

fn test_writes() {
	b := blog()!
	g := b.g
	ada := b.ada
	// snippet: create
	v := g.tags().create().set_name('v-lang').save()!
	article := g.articles().create()
		.set_author(ada) // or .set_author_id(ada.user.id)
		.set_title('Writing with vgraph')
		.add_tags(v) // writes the join row
		.save()! // graph.ArticleNode, read back with its defaults
	// end snippet
	assert article.article.status == .draft
	// snippet: update
	article.update().set_title('Writing, with vgraph').set_status(.published).add_views(1).exec()!
	n := g.articles().update().where_status(.draft).set_status(.archived).exec()! // rows changed
	g.articles().update_one_id(article.article.id).remove_tags(v).exec()!
	// end snippet
	assert n == 1
	// snippet: delete
	g.comments().delete().where_body('Nice!').exec()!
	g.articles().delete_one(article).exec()! // soft: the model's hook sets deleted_at
	gone := g.skip('soft_delete').articles().where_deleted_at_is_not_null().count()!
	// end snippet
	assert gone == 1
	// snippet: bulk
	tags := g.tags().create_bulk(g.tags().create().set_name('orm'), g.tags().create().set_name('graphql')).save()!
	// an upsert: a name taken already keeps its row
	g.tags().create().set_name('orm').on_conflict_columns('name').ignore().exec()!
	// end snippet
	assert tags.len == 2 && g.tags().count()! == 5
}

fn test_validation() {
	b := blog()!
	g := b.g
	// snippet: validation
	g.articles().create().set_author(b.ada).set_title('').exec() or {
		assert err is vgraph.ValidationError
		println(err) // `articles.title`: is empty
	}
	g.articles().create().set_title('No author').exec() or {
		println(err) // `articles.user_id`: the edge `author` is required
	}
	// end snippet
	if _ := g.articles().create().set_author(b.ada).set_title('').save() {
		assert false
	} else {
		assert err.msg() == '`articles.title`: is empty'
	}
	if _ := g.articles().create().set_title('No author').save() {
		assert false
	} else {
		assert err.msg() == '`articles.user_id`: the edge `author` is required'
	}
}

fn test_transactions() {
	b := blog()!
	g := b.g
	// snippet: tx
	g.tx(fn (tx graph.Graph) ! {
		cy := tx.users().create().set_name('Cy').set_email('cy@example.com').save()!
		tx.articles().create().set_author(cy).set_title('First post').exec()!
		tx.on_commit(fn () {
			println('Cy is in')
		})
	})!
	// an error rolls the whole transaction back
	g.tx(fn (tx graph.Graph) ! {
		tx.users().create().set_name('Dee').set_email('dee@example.com').exec()!
		return error('changed my mind')
	}) or { println(err) }
	// end snippet
	assert g.users().where_name('Cy').exist()!
	assert !g.users().where_name('Dee').exist()!
}
