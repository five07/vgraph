// Package catalog holds the example's data, its migration and its seed. The
// data is made by formulas, so the checks can work out what each page holds.
module catalog

import orm
import v.migrations
import five07.vgraph
import graph

// author_count and book_count are the numbers of authors and books the seed
// adds.
pub const author_count = 40
pub const book_count = 300

const first_names = ['Ada', 'Ben', 'Cora', 'Dev', 'Eli', 'Fay', 'Gus', 'Hana']!
const last_names = ['Moss', 'Ng', 'Okafor', 'Park', 'Quinn']!

// author_name returns the name of the author with the id `id`, from 1: the
// names repeat no pair, and sort in another order than the ids.
pub fn author_name(id int) string {
	n := id - 1
	return '${first_names[(n * 3) % first_names.len]} ${last_names[n % last_names.len]}'
}

// author_born returns the year the author `id` was born.
pub fn author_born(id int) int {
	return 1900 + (id * 37) % 100
}

// book_title returns the title of the book `id`, such as `Book 007`.
pub fn book_title(id int) string {
	return 'Book ${id:03}'
}

// book_year returns the year of the book with the id `id`: 75 years over 300
// books, so each year has about four books, which an order by year breaks
// by id.
pub fn book_year(id int) int {
	return 1950 + (id * 53) % 75
}

// book_pages returns the number of pages of the book `id`.
pub fn book_pages(id int) int {
	return 100 + (id * 89) % 600
}

// book_authors returns the ids of the authors of the book `id`: one, and a
// second on every third book.
pub fn book_authors(id int) []int {
	first := (id - 1) % author_count + 1
	second := (id * 7) % author_count + 1
	return if id % 3 == 0 && second != first { [first, second] } else { [first] }
}

// initial is the example's one migration: the two tables, with
// auto-incrementing keys, the join table, and the indexes the edges need.
const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      initial_up
	down:    initial_down
}

fn initial_up(mut ctx migrations.Context) ! {
	s := graph.schema()!
	vgraph.create_table(mut ctx, s, 'authors')!
	vgraph.create_table(mut ctx, s, 'books')!
	ctx.create_table(s.join_table('authors', 'books')!)!
	vgraph.add_edge_indexes(mut ctx, s)!
}

fn initial_down(mut ctx migrations.Context) ! {
	for table in ['book_authors', 'books', 'authors'] {
		ctx.drop_table(table)!
	}
}

// migrate applies `initial` to `db`, recording it in the table `table`.
pub fn migrate(mut db orm.TransactionalConnection, dialect migrations.Dialect, table string) ! {
	mut m := migrations.new(mut db, [initial], dialect: dialect, table: table)!
	m.migrate()!
}

// seed adds the authors and books, in one transaction, unless there are
// authors already.
pub fn seed(g graph.Graph) ! {
	if g.authors().count()! > 0 {
		return
	}
	g.tx(fn (tx graph.Graph) ! {
		mut authors := []graph.AuthorCreate{}
		for id in 1 .. author_count + 1 {
			authors << tx.authors().create().set_name(author_name(id)).set_born(author_born(id))
		}
		tx.authors().create_bulk(...authors).exec()!
		mut books := []graph.BookCreate{}
		for id in 1 .. book_count + 1 {
			books << tx.books().create().set_title(book_title(id)).set_year(book_year(id)).set_pages(book_pages(id)).add_authors_ids(...book_authors(id))
		}
		tx.books().create_bulk(...books).exec()!
	})!
}
