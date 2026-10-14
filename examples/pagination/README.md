# pagination

A GraphQL server whose lists page the two ways vgraph offers, on 40 authors and
300 books (<https://graphql.org/learn/pagination/>):

- **authors** are plain lists: `limit` and `offset`, like SQL's;
- **books** are Relay connections (`relay: true` in `models/models.v`): `first` /
  `after` and `last` / `before`, with cursors, `pageInfo` and `totalCount`.

Each author has books, and each book one or two authors, so each kind also shows
up nested under the other, paged per parent.

```sh
v run ../setup.vsh # once per checkout: makes it importable as five07.vgraph
v run .            # serves http://localhost:8080/graphql; PORT changes the port
v test .           # the checks, on SQLite
```

The data lives in an in-memory SQLite database, seeded at startup by formulas
(`catalog/catalog.v`), so the tests can work out what every page holds.

## Which to use

|                          | Lists: `limit` / `offset`              | Connections: `first` / `after`              |
|--------------------------|----------------------------------------|---------------------------------------------|
| Turn on                  | the default                            | `relay: true` in the model's `graphql()`    |
| Jump to page *n*         | yes: `offset: (n - 1) * size`          | no: pages follow from a cursor              |
| A write between requests | rows shift: one shows twice, or never  | the next page starts after the last row seen |
| Paging backwards         | another order (`direction: DESC`)      | `last` / `before`                           |
| How many in all          | the root `authorsCount(where:)` field  | `totalCount`, counted only when asked for   |
| Deep pages               | the database still reads and skips the rows before `offset` | `after` is a condition on the order's columns, which an index on them serves |
| Clients                  | anything                               | Relay, Apollo's `relayStylePagination`, urql |

Use lists for small, fixed sets, admin screens with page numbers, and nested
lists that only show a few items. Use connections for feeds, infinite scroll,
anything that grows or changes while someone reads it, and for Relay clients.
Connections don't take `offset` - offset pages are what lists are
for.

## Lists

A page is `limit` rows after skipping `offset`, in `orderBy`'s order. Order by
something unique, or something then the key, so a page boundary can't split ties
differently from one request to the next. The last page is the one that comes
back short; `authorsCount` takes the same `where` when a client shows a total.

```graphql
{ authorsCount authors(orderBy: {field: NAME}, limit: 3, offset: 0) { name born } }
```

```json
{"data":{"authorsCount":40,"authors":[{"name":"Ada Moss","born":1937},{"name":"Ada Ng","born":1929},{"name":"Ada Okafor","born":1921}]}}
```

The next page is `offset: 3`. `orderBy: {field: NAME, direction: DESC}` reads them
from the end.

## Connections

A connection returns `edges`, each a `node` and its `cursor`, and `pageInfo`. Ask
for `first: n`, then pass the last page's `endCursor` as `after`:

```graphql
{ books(first: 3, orderBy: {field: YEAR}) {
    totalCount
    edges { cursor node { title year } }
    pageInfo { hasNextPage hasPreviousPage startCursor endCursor } } }
```

```json
{"data":{"books":{"totalCount":300,"edges":[
  {"cursor":"WyIxOTUwIiwiNzUiXQ","node":{"title":"Book 075","year":1950}},
  {"cursor":"WyIxOTUwIiwiMTUwIl0","node":{"title":"Book 150","year":1950}},
  {"cursor":"WyIxOTUwIiwiMjI1Il0","node":{"title":"Book 225","year":1950}}],
  "pageInfo":{"hasNextPage":true,"hasPreviousPage":false,
    "startCursor":"WyIxOTUwIiwiNzUiXQ","endCursor":"WyIxOTUwIiwiMjI1Il0"}}}}
```

```graphql
{ books(first: 3, after: "WyIxOTUwIiwiMjI1Il0", orderBy: {field: YEAR}) {
    edges { node { title year } } pageInfo { hasNextPage endCursor } } }
```

```json
{"data":{"books":{"edges":[{"node":{"title":"Book 300","year":1950}},{"node":{"title":"Book 017","year":1951}},{"node":{"title":"Book 092","year":1951}}],
  "pageInfo":{"hasNextPage":true,"endCursor":"WyIxOTUxIiwiOTIiXQ"}}}}
```

Backwards is `last: n`, then the page's `startCursor` as `before`, while
`hasPreviousPage` is true. The edges still come in the connection's order:

```graphql
{ books(last: 2, orderBy: {field: YEAR}) { edges { node { title year } } pageInfo { hasPreviousPage startCursor } } }
```

```json
{"data":{"books":{"edges":[{"node":{"title":"Book 208","year":2024}},{"node":{"title":"Book 283","year":2024}}],
  "pageInfo":{"hasPreviousPage":true,"startCursor":"WyIyMDI0IiwiMjA4Il0"}}}}
```

What to know:

- **Cursors are opaque.** One holds the row's values of the order and its key
  (base64 of `["1950","225"]` above), so it only works with the order it came
  from: with another `orderBy`, or edited, it is an `invalid cursor` error. A
  connection always orders by the key last, so its order is total and no row
  falls between two pages.
- **`hasPreviousPage` is false when paging forwards**, and `hasNextPage` when
  paging backwards, as the Relay spec allows: the server doesn't run a second
  query to find out. Page forwards with `hasNextPage`, backwards with
  `hasPreviousPage`.
- **`totalCount` is a second query**, run only when the request asks for it.
  `first: 0` returns it with no edges.
- **An order other than the key needs a vgraph driver**
  (`five07.vgraph.sqlite` or `five07.vgraph.pg`), as the server here uses: two
  order columns and a cursor condition on both are SQL the ORM can't run.
- `first` and `last` together, or a negative one, are errors (see
  [Page sizes](#page-sizes) for the largest).

## Nested, per parent

A list or connection on an edge pages each parent's rows on its own, in one
statement for all the parents (a window function, with a driver). Each author's
two earliest books, and how many it has:

```graphql
{ authors(orderBy: {field: ID}, limit: 2) {
    name
    books(first: 2, orderBy: {field: YEAR}) { totalCount edges { node { title year } } pageInfo { hasNextPage endCursor } } } }
```

```json
{"data":{"authors":[
  {"name":"Ada Moss","books":{"totalCount":10,"edges":[{"node":{"title":"Book 201","year":1953}},{"node":{"title":"Book 081","year":1968}}],
    "pageInfo":{"hasNextPage":true,"endCursor":"WyIxOTY4IiwiODEiXQ"}}},
  {"name":"Dev Ng","books":{"totalCount":10,"edges":[{"node":{"title":"Book 242","year":1951}},{"node":{"title":"Book 122","year":1966}}],
    "pageInfo":{"hasNextPage":true,"endCursor":"WyIxOTY2IiwiMTIyIl0"}}}]}}
```

To read further into one author's books, select that author and pass its
`endCursor`: `authors(where: {id: "1"}) { books(first: 2, after: "WyIxOTY4IiwiODEiXQ", orderBy: {field: YEAR}) { ... } }`.

A nested list takes `limit` and `offset` per parent the same way:
`books(first: 10) { edges { node { title authors(orderBy: {field: NAME}, limit: 1) { name } } } }`
gives each book its first author by name.

However many parents and rows a page has, it runs the same statements: one per
edge per level, plus the counts asked for (`check_statements`).

## Page sizes

A negative `limit`, `offset`, `first` or `last` is an error. How many rows a page
may hold, and how many one gets when a request gives no size, are options:

```v ignore
// every table: 20 rows when a request gives no size, never more than 50
server := g.graphql(graph.Resolvers{}, default_page: 20, max_page: 50)!

// one table, in its model: its own maximum, which wins over the server's
pub fn (b Book) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{relay: true, max_page: 100}
}
```

They bound the table's lists and connections at the root and on edges (per
parent). A request past the maximum fails, such as
`` `limit` on a list cannot be more than 50. ``; without a size it gets the
default, or the maximum when there is no default, so a maximum always holds.
Without either, a list without `limit` returns every row. The server here
uses the values above (`main.v`), and `check_page_sizes` checks them.

## Writes between pages

`check_writes_between_pages` shows the difference that matters most. A client
reads the first five authors by name, someone adds "Aaron Abbot", and the client
asks for `offset: 5`: every row has moved down one, so the fifth author shows
again. The same with books: read the first five by year, add a book from 1900,
ask for `after: <endCursor>`, and the page starts right after the fifth book read,
as if nothing had changed. The new book is on the first page, for whoever reads
it next.

## Layout

```
main.v               the server: migrate, seed, serve /graphql on veb
models/models.v      Author (lists) and Book (relay: true), linked through book_authors
graph/               the client and GraphQL server, from `vgraph gen`
catalog/catalog.v    the data's formulas, the migration and the seed
checks/checks.v      the checks: lists, connections, nested, statements, writes
main_test.v          the checks on SQLite; pg_test.v on PostgreSQL (-d vgraph_pg)
```

After changing a model, run `v run ../../cmd/vgraph gen` here.
