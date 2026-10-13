# vgraph: research and plan

An Ent-style ([entgo.io](https://entgo.io)) graph layer for V: edges declared once,
loaded in batches and traversed through a typed API, with schema changes applied
through V's own `v.migrations` module. It would be published on VPM as
`five07.vgraph`.

Questions are marked **Q** with a `> A:` line for your answer. Anything I've assumed is
marked **Default**.

---

## 1. Reference: V modules and VPM

### Links

| What | Where |
|------|-------|
| VPM, the package registry | <https://vpm.vlang.io> |
| Submit a package (GitHub login) | <https://vpm.vlang.io/new> |
| VPM's own source | <https://github.com/vlang/vpm> |
| Docs: creating modules | <https://docs.vlang.io/modules.html> |
| Docs: package management and publishing | <https://docs.vlang.io/package-management.html> (see "Publish package") |
| VPM guide: version ranges, lockfile | <https://github.com/vlang/v/blob/master/cmd/tools/vpm/README.md> |
| Standard library docs | <https://modules.vlang.io> |
| V ORM README (relations, `include`, joins) | <https://github.com/vlang/v/blob/master/vlib/orm/README.md> |

The same docs are in your checkout. It is V master at `53dd72c` (2026-10-12), which
reports itself as `V 0.5.2` but is 86 commits past the `0.5.2` tag (see Q13):
`~/Projects/vlang/v/doc/docs.md` ("Modules" around line 4285, "Package management"
around line 7664, "Publish package" around line 7912), `cmd/tools/vpm/README.md`, and
`vlib/orm/README.md`.

### What matters for a package

- **Module vs package:** a *module* is one folder of `.v` files sharing a `module`
  name. A *package* is one or more modules with a `v.mod` at the top, which also
  anchors imports (`import vgraph.load` resolves against the folder holding `v.mod`).
- **Names:** `snake_case`, and the docs say under 10 characters (`vgraph` is 6). VPM
  lowercases a name and turns `-` into `_` when installing.
- **Starting a project:** `v new --lib vgraph` creates `v.mod`, a library template
  and a git repository. `--agents-md` also writes an `AGENTS.md` contributor file.
- **`v.mod` fields:** `name`, `description`, `version`, `license`, `dependencies` (a
  string list, which may carry semver ranges such as `'vsl@^0.1.47'`), and optional
  `base_url` (the source folder) and `subdirs`.
- **Lockfile:** `v install` inside a project writes `v.mod.lock`. Commit it, and use
  `v install --locked` in CI.
- **Install locations:** `~/.vmodules` by default (`VMODULES` overrides it), or
  `v install --local` to install beside the project's own modules.
- **Publishing:**
  1. push a public GitHub repo with `v.mod` at its root;
  2. submit it at <https://vpm.vlang.io/new>, logged in with GitHub;
  3. it is then installed as `<github-user>.vgraph`.

  **The VPM entry can't be edited after submission, so check the name and repo URL
  first.** Tag the repo `vlang` and `vlang-package` on GitHub so it shows up in searches.
- **Releases:** semver tags (`v0.1.0`). VPM's version ranges select tags, and
  prereleases need an explicit prerelease constraint.
- **API docs:** `v doc` generates them from doc comments, so every `pub` item needs
  one, as in `rest-api`.

## 2. Prior art (checked 2026-10-12)

- **On VPM:** `v search` for `orm`, `graph`, `vgraph` and `dataloader` found no
  graph or edge-loading library. `vgraph` is unclaimed. The only near matches:
  - `luizfonseca.graphql`: a GraphQL *parser* only, work in progress, last updated
    about 3 years ago. It might serve as the parsing half of a GraphQL layer later.
  - `ghostnear.storm` / `ghostnear.vstorm`: an app framework for `gg` GUIs, unrelated.
- **V's ORM** (vlib, V 0.5.2) is relational:
  - has-many through `[]Child @[fkey: 'parent_id']`;
  - belongs-to through a struct-typed field;
  - implicit loading of those relations in `sql { }` blocks, or opt-in
    `include()` / `then_include()` in the `orm.new_query[T]` function API;
  - `join` / `left join` inside `sql { }`;
  - `@[references]` foreign keys.
  - **Gaps:** relation loading runs **one query per parent row** (stated in its
    README), there are no edge declarations, no generated client, and no polymorphic
    relations.
- **V's migrations** (`vlib/v/migrations`, added to master 2026-10-10, so **not** in
  the `0.5.2` tag): ordered, reversible migrations registered in V code
  (`migrations.new(mut db, [Migration{version, name, up, down}], Config{dialect: .sqlite})`),
  with `create_table`, `add_column`, `add_index` (normal and unique), `add_foreign_key`,
  `create_orm_table[T]`, and `migrate` / `rollback` / `redo` / `status`, for SQLite,
  Postgres and MySQL. Its tests pass on your local compiler. It doesn't diff a schema
  against the database or generate migration files: migrations are written by hand.
  The [announcement](https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)
  calls it `v3.migrations`; on master it is now `import v.migrations`.
- **Ent's model, which vgraph borrows:** a schema with `Fields()` and `Edges()`
  ([edges docs](https://entgo.io/docs/schema-edges)), a generator (`entc`) that writes
  a typed client, eager loading with `With<Edge>()` batched per level, traversal with
  `Query<Edge>()`, and migrations through [Atlas](https://atlasgo.io). vgraph uses
  `v.migrations` in place of Atlas (Q10).

## 3. Goals

1. **Batched edge loading:** loading an edge for N parents takes one query, not N. This
   is the core of the library, and what GraphQL resolvers need.
2. **Declared edges:** relationships are described once and checked when the program
   starts (`Client.new` validates every edge against the structs).
3. **Typed traversal and queries:** `client.articles().with_comments().all()!` and
   `article.query_comments().query_author().all()!`, through code generation.
4. **Built on `orm.Connection`**, so any adapter the ORM has (SQLite, Postgres, MySQL)
   works.

**Non-goals for v1:** Gremlin or other graph databases, hooks/privacy policies, GraphQL
execution (Q9: a separate `five07.graphql` package if wanted), and a migration engine of
its own (Q10: `v.migrations` runs them).

## 4. Design

### Edges

As built in Phase 2 (`edge.v`):

```v ignore
pub enum EdgeKind {
	one_to_many  // Article.comments: the target table holds this record's id
	one_to_one   // User.card: as one_to_many, but at most one (added in Phase 3)
	many_to_one  // Comment.author: this table holds the target's id
	many_to_many // Article.tags: through a join table
}

pub struct Edge {
pub:
	name       string   @[required] // 'comments'
	kind       EdgeKind @[required]
	to         string   @[required] // target table: 'comments'
	column     string   @[required] // 'owner_id', 'user_id'; for many_to_many, the join column for this record
	type_col   string   // polymorphic: 'owner_type'
	type_val   string   // polymorphic: 'Article'
	through    string   // many_to_many: the join table
	through_to string   // many_to_many: the join column for the target
	soft_del   string   // optional: 'deleted_at', filtered as IS NULL (Q7)
}
```

Changes from the first draft:
- **No `polymorphic` kind.** `type_col` / `type_val` work on both directions: on a
  `one_to_many` edge they filter the targets (`Article.comments`), and on a
  `many_to_one` edge they filter the records followed (`Comment.article`).
- **No `from` field.** `Schema.add[T]()` knows the declaring table.
- **`through_to` is new.** A join table has two key columns.
- **`one_to_one` is new** (Phase 3, after reviewing Ent's relationship kinds). It is
  the side without the foreign key; `ensure_indexes` makes its index unique.

Ent's relationship kinds map onto these four. `examples/relations` declares and
tests each one:

| Ent | vgraph |
|-----|--------|
| O2O two types (user, card) | `one_to_one` + `many_to_one` |
| O2O same type (linked list next/prev) | self `many_to_one` + self `one_to_one` |
| O2O bidirectional (spouse) | self `many_to_one`, set on both rows by the app |
| O2M two types (user, pets) | `one_to_many` + `many_to_one` |
| O2M same type (tree) | self `one_to_many` + self `many_to_one` |
| M2M two types (groups, users) | `many_to_many` on both sides, join columns swapped |
| M2M same type (following, followers) | two self `many_to_many` edges, join columns swapped |
| M2M bidirectional (friends) | self `many_to_many`, each pair stored both ways by the app |

vgraph only reads, so a bidirectional edge is the app's job to write both ways.

`example` declares `users → articles/posts/comments`, `articles/posts → author`,
`articles/posts → comments` (polymorphic), and `comments → author/parent/article/post`
plus `replies`.

### Layers, in build order

| Layer | What | How | Phase |
|-------|------|-----|-------|
| `vgraph.load` | `load_one[C, P](conn, children, fk)`, `load_many[P, C](conn, parents, fk)`, `load_through` (join table): one `WHERE col IN (…)` per edge, de-duplicated ids | compile-time reflection (`$for field in T.fields`) plus `orm.Connection.select` (Q17) | 1–2 |
| `vgraph` (`Schema`, `Client`) | each entity declares `fn (Article) edges() []vgraph.Edge` (Q4); `Schema.add[T]()` reflects it; `Client.new` checks every edge; `client.load_one` / `load_many` load by edge name | plain V, checked at startup | 2 |
| `vgraph gen` | a CLI that reads the schema and writes `client/*.v`: typed `with_<edge>()`, `query_<edge>()`, field predicates | code generation, like `entc` | 3 |
| GraphQL adapter | resolvers backed by `vgraph.load` batching | a separate `five07.graphql` package, maybe on top of `luizfonseca.graphql` | 4 (Q9) |
| migration helpers | turn declared edges into `v.migrations` steps: an index on every edge column, foreign keys, the join tables for many-to-many | helpers that return `migrations.Index` / `ForeignKey` / `Table`; `v.migrations` runs them | 5 (Q10) |

**Why split reflection and code generation:** V's compile-time reflection reads fields
and attributes, which is enough for generic loading. It **can't create methods**, so
typed traversals (`.query_comments()`) and predicates (`article.title_contains('V')`)
need a generator, which is the same reason Ent has `entc`.

**SQL:** `sql { }` blocks are fixed at compile time. Even `dynamic select` only switches
whole conditions on or off; the column names stay fixed. So vgraph can't use them for an
edge column it only knows at runtime. Two routes work (Phase 0 tested both), and Q17
chooses between them:
- `orm.new_query[T](conn).where('${col} IN ?', ids)`, the ORM's function API. It is
  **deprecated**: it leaves the standard library after 2027-08-17 (notices now,
  warnings from 2027-02-18; [vlang/v#27001](https://github.com/vlang/v/issues/27001)).
- `orm.Connection.select(SelectConfig, QueryData, where)`, the driver interface every
  adapter implements, with vgraph mapping the rows back into `T` through `$for`. It
  isn't deprecated, but vgraph then maps every field type itself.

Either way, vgraph avoids `@[fkey]` and the ORM's implicit relation loading, which makes
N+1 queries.

## 5. V 0.5.2 risks, from building `rest-api`

| Found in rest-api | What it means for vgraph | Mitigation |
|-------------------|--------------------------|------------|
| Generics across modules: codegen bugs `../web` works around; a false "unused function" notice | vgraph is mostly generics, so it will hit more | build against your local V master for now and pin a `0.5.x` release before `v0.1.0` (Q13); keep a `regressions/` test folder with one small test per compiler bug, each reported upstream with a fix PR where we can (Q11) |
| `@[index]` creates no index on SQLite | edge columns need indexes | `ctx.add_index` in a `v.migrations` migration (raw `CREATE INDEX IF NOT EXISTS` only before Phase 5) |
| `sqlite.DB.exec` ignores errors raised while a statement runs | silent failures in hand-written SQL | always `exec_param_many`, or the ORM |
| a variable named `update` inside `sql { }` silently skips the statement | — | mostly avoided by not using `sql { }`; a lint rule |
| the ORM's `last_insert_rowid()` races across threads | inserts return the wrong id | look rows up by a unique key; transactions |
| macOS libsqlite3 is in multi-thread mode | crashes under concurrency | document `connect_full(..., [.fullmutex])`; test with concurrent requests |
| `@[references]` columns are nullable | — | `sql_type: 'INTEGER NOT NULL'` |
| `orm.new_query` (the function API) leaves vlib after 2027-08-17 | the plan's query layer goes away | build on `orm.Connection.select` (Q17) |

Phase 0 checks the reflection that the loader depends on before anything else is built.

## 6. Phases

**Phase 0: reflection spike** (in this repo, under `spike/`, about a day).
Confirm that, on your local V master (Q13), a generic function in one module can:
- read `T`'s fields and attributes;
- run `orm.new_query[C](conn)` with a `where … in […]` condition built at runtime;
- group the rows by a column whose name it only knows at runtime.

Also write a short README.md for your first commit on `main` (this repo has none
yet).

*Exit:* a test that loads comments for 3 articles in one query.

*Result (2026-10-12, done):* `spike/` passes on local master `53dd72c`. A generic
`load_many[P, C]` in the `load` module reads `@[primary]`, `@[sql: 'col']` and
`@[table]` through `$for`, queries `owner_id IN (…)` once for 3 articles (one of them
repeated), and groups the rows by a column named at runtime. A `CountingConnection`
(Q16) asserts the query count. No compiler workarounds were needed. Both query routes
in Q17 pass the same test.

**Phase 1: dogfood in `example/`.** Copy `rest-api` into `example/` in this repo (Q14).
It becomes the test bed for each feature and, later, the published example. Then:
1. before changing anything, run its tests and record a baseline of the SQL each
   endpoint runs (Q16);
2. replace `slugs_of` + `app.distinct` + the `Owner` registry's loading with
   `vgraph.load`, in-tree at first (Q15).

`~/Projects/vlang/rest-api` itself is left alone.

*Exit:* every `example` test still passes, and the traced SQL shows the same number of
queries or fewer than the baseline.

*Result (2026-10-12, done):* `example/` holds `rest-api` at `9d802d6`, renamed. Its
loading now runs through `example/vgraph/load` (`load_one`, `load_many`, polymorphic
via `Poly`), built on `orm.Connection.select` (Q17). `slugs_of` (four stores),
`app.distinct` and the registry's slug loading are gone; the registry keeps `id_of`.
`test_read_endpoints_query_counts` asserts the selects of 15 read endpoints, and gives
the same list before and after the swap (`rest-api` already batched). All 11 test files
pass. One compiler bug turned up: `vgraph/regressions/comptime_generic_call.vv`.

**Phase 2: standalone package.** Add `v.mod` (`name: 'vgraph'`, MIT) to this repo's root;
`v new --lib` would make a new folder, so copy what it generates instead. Move the
`Edge` and `schema` layers there, with a SQLite test suite and a Postgres CI job (Q3).
Before publishing, pin to a `0.5.x` release that includes `v.migrations` (Q13), and
record it in the README and CI. Then publish `v0.1.0` to VPM from
`github.com/five07/vgraph`.
*Exit:* `v install five07.vgraph` works in a fresh project, and `example` imports it.

*Result (2026-10-12, built; not yet published):*
- **Package:** `v.mod` (with `repo_url`) and the template's `.editorconfig` and
  `.gitattributes` are at the root.
- **`vgraph` module:** `Edge`, `Schema` and `Client` (`edge.v`, `schema.v`,
  `client.v`). `load/` moved up from `example/vgraph/load`. Inside the package the
  root imports it as plain `import load`: `import vgraph.load` fails in the repo's own
  tests, and `import five07.vgraph.load` only works through the `~/.vmodules` link.
- **`example`:** imports `five07.vgraph` through `~/.vmodules/five07/vgraph` (a link
  to this repo), declares `edges()` on its four models, and loads through
  `vgraph.Client`. Its query-count test is unchanged.
- **Tests:** `vgraph_test.v` (schema, validation, every edge kind),
  `load/load_test.v` (soft delete, join tables), and `pg_test.v` on PostgreSQL. All
  14 test files pass, `pg_test.v` against a local PostgreSQL 18.
- **CI:** `.github/workflows/ci.yml` runs `v fmt -verify`, `v vet` on the package,
  `v test` on SQLite, and `pg_test.v` against a `postgres:16` service, with V built
  at `53dd72c`. It hasn't run yet: it first runs on push.
- **Your decisions (2026-10-12):**
  - CI runs only on pushes to `main`, which include merges.
  - Keep building on V master. Until a release includes `v.migrations`,
    `Client.ensure_indexes()` (`migrate.v`) creates the indexes edges need with
    `CREATE INDEX IF NOT EXISTS`, and `example` uses it in place of its hand-written
    index. Phase 5 replaces it.
  - The whole plan is finished on `develop` before merging to `main` and tagging
    `v0.1.0`. VPM submission waits on VPM's OAuth problem.
  - The exit test (`v install five07.vgraph` in a fresh project) runs once the
    package is on VPM.
- `pg_test.v` runs only with `-d vgraph_pg`. `started_postgres` turned it on
  whenever any PostgreSQL process was running locally.

**Phase 3: generator.** First, the schema comparison from Q4: write the `example`
entities both as (a) `edges()` methods and as (c) a schema file, and choose one before
building `vgraph gen` on it. Then `vgraph gen` writes the typed client, and `example`
switches to it.
*Exit:* `example` uses no hand-written loading code.

*Result (2026-10-12, done; Q18 chose (a)):*
- **`vgraph gen [folder] [--out graph]`** (`cmd/vgraph`, logic in `gen/`) finds the
  structs with `edges()` by scanning the sources. It writes and runs a loader
  program in `.vgraph-gen/`, which registers them, validates the schema and prints
  it as JSON. It then writes `graph.v` plus one file per table, removes stale
  generated files (it never touches files without its header), and runs `v fmt`.
  Schema problems are reported as such, with exit code 1.
- **Generated API per table:**
  - typed predicates by column type (`where_<field>`, `_lt/_le/_gt/_ge`, `_in`,
    `_like`, `_is_null/_is_not_null`), plus `where(load.Cond...)` for anything else;
  - `order_by_<field>[_desc]`, `limit`;
  - `with_<edge>(configure ...)` for nested eager loads, one query per edge;
  - `all`, `first` (`NotFoundError`), and `nodes(rows)` to load edges onto rows
    you already have;
  - on each node, `query_<edge>()` for traversal (`!` for many_to_many, which
    reads the join table first).
- **Support code:**
  - `load` gained `Cond` / `Query` / `select_where` (conditions, order, limit),
    `link_pairs` and `unique`;
  - `Schema` keeps columns in field order, with their V field names and types, and
    tables in registration order.
- **`example`:** uses `example/graph/`, generated and checked in. Its comment,
  article and post views load through it. The `Owner` registry is down to `id_of`.
  The query-count test is unchanged: the same selects, in the same order. The
  stores keep their own root queries (`find_by_user` and similar), which are queries
  rather than edge loading.
- **Tests:** `gen/gen_test.v` (discovery, naming, the loader) and
  `cmd/vgraph/gen_test.v`, which generates a client for a throwaway project with a
  join table, a polymorphic edge in both directions, a nullable self-edge and soft
  deletes, and runs that project's tests against it, query counts included. All 16
  test files pass, PostgreSQL included.
- **CI:** CI fails if `example/graph` isn't what `vgraph gen` produces from the
  current models.
- **Compiler bugs found:** a second one, `regressions/shadowed_fn_call.vv`: a
  variable named like the function it calls generates invalid C on master.
- **Relationship coverage (added after review):** `one_to_one` was missing, so the
  user side of O2O came out as a list. Added to the core, the runtime `Client`,
  unique indexes and the generator (`?&Node`, first row wins).
  `examples/relations` has a test for each of Ent's eight kinds. The generator now
  rejects table and edge names its output needs for itself.

*Schema comparison (2026-10-12), for Q18: chose (a).* `example` had the same schema
both ways, (a) `edges()` on each model and (c) a `schema.toml`, with a test that they
declared identical edges. Both were removed once (a) was chosen.

| | (a) `edges()` methods | (c) `schema.toml` |
|---|---|---|
| Where | next to each struct | one file for the whole graph |
| Checked | kinds and names by the compiler; columns at `Client.new` | names when parsed; columns at `Client.new` (if a runtime `Schema` is built from it) |
| Fields for predicates | reflection, from the real structs | must be listed again in the file, or taken from the structs anyway |
| How `vgraph gen` reads it | writes a small program that imports the models and dumps the reflected schema as JSON, runs it (a few seconds), and generates from the JSON | parses the file: fast, no compile, if fields are listed |
| Runtime without gen | works today (`Schema.add[T]()`) | needs a loader that maps tables to structs, so in practice still `add[T]()` |
| Non-V tools (GraphQL, migrations) | read the JSON that gen dumps | read the file directly |

Either way the generated client is the same. Sketch, for `articles`:

```v ignore
// example/graph/articles.v, generated
pub fn (g Graph) articles() ArticleQuery
pub fn (q ArticleQuery) where_slug(slug string) ArticleQuery          // field predicates
pub fn (q ArticleQuery) with_author() ArticleQuery                     // eager loads, batched
pub fn (q ArticleQuery) with_comments(f fn (CommentQuery) CommentQuery) ArticleQuery
pub fn (q ArticleQuery) all() ![]ArticleNode
pub fn (q ArticleQuery) only() !ArticleNode
pub struct ArticleNode {
pub:
	article  article_models.Article
	author   ?UserNode      // set by with_author()
	comments []CommentNode  // set by with_comments()
}
pub fn (n ArticleNode) query_comments() CommentQuery                  // traversal
```


**Phase 3.1: Ent relationships, and `examples/`** (2026-10-12, done).
- **Layout:** `example/` moved to `examples/service/`, renamed `service`. Earlier
  phases call it `example`.
- **New example:** `examples/relations/` covers every Ent relationship kind (table
  under Design).
- **Shared checks:** the checks live in `checks.v`, so the same nine run on SQLite
  (`main_test.v`) and on PostgreSQL (`pg_test.v`, `-d vgraph_pg`). Both pass.
- **What the checks cover:** for each kind, eager loading (`with_<edge>`, nested
  where it applies), every generated traversal (`query_<edge>`, 14 of 14), the
  queries run (one per edge, two through a join table), and missing targets
  (`none` and empty lists). For `one_to_one`, the unique index rejects a second
  card for the same user.
- **CI:** the PostgreSQL job runs both PostgreSQL tests. The generated-code check
  covers both examples.

**Phase 4: GraphQL.** Without it, vgraph can't serve GraphQL to a client at all:
it has no GraphQL schema, parser or executor, and V's standard library has none.
So it is built here, in this repo, and moved to its own package (`five07.graphql`)
later if that's needed (2026-10-12; revises Q9). Scope questions: Q19.

**Phase 5: migration helpers** for `v.migrations` (Q10): from the declared edges,
produce the indexes, foreign keys and join tables as `migrations.Index` /
`ForeignKey` / `Table` values, for migrations written by hand. `examples/service` moves its
table setup to `v.migrations`.

## 7. Questions

**Q1.** Repository and name: a GitHub repo `vgraph` under which account? The VPM name
becomes `<account>.vgraph`, and it can't be changed after submission.
> A: `five07` - this is the repo I will use.

**Q2.** V version: pin to 0.5.2 (stable to build against, but slower to get fixes),
or follow V master (fixes arrive sooner, along with API churn)? **Default:** pin, and
bump on purpose.
> A: yes, pin to 0.5.2 for now
>
> *Superseded by Q13: follow local master, and pin a `0.5.x` release before publishing.*

**Q3.** Databases: SQLite only for v1, or Postgres too (the `rest-api` stretch
goal)? **Default:** SQLite first, with Postgres in CI from Phase 2.
> A: SQLite first, with Postgres in CI from Phase 2.

**Q4.** How entities declare edges. **Default:** (a), plain and checkable.
- (a) a method, `fn (Article) edges() []vgraph.Edge`, like Ent's `Edges()`;
- (b) struct attributes, `@[edge: 'comments; to: Comment; fk: owner_id']`, which
  are compact but are stringly typed and only checked at runtime;
- (c) a separate schema file that `vgraph gen` reads.
> A: hmm, start with (a) and later let's test an example of (a) and (c) and then we'll decide. Works with Q5

**Q5.** Code generation in v1, or reflection-only loading first (Phases 0–2) with
the generator later? **Default:** reflection first; it shows sooner whether V's
generics hold up.
> A: default choice

**Q6.** Identifiers: assume an `int` primary key named `id` (Ent's default), with
slugs left to the app as in `rest-api`? **Default:** yes, with the key column
configurable per entity.
> A: default choice

**Q7.** Soft delete as a built-in edge option (`soft_del: 'deleted_at'`), since
`rest-api` filters it everywhere? **Default:** yes, opt-in per edge.
> A: default choice

**Q8.** Polymorphic edges in v1? They're the hardest kind and the one `rest-api`
needs most. **Default:** yes. Without them Phase 1 can't replace the `Owner` registry.
> A: default choice

**Q9.** GraphQL: build an executor in vgraph, adapt `luizfonseca.graphql` (parser
only, inactive for about 3 years), or keep GraphQL a separate project? **Default:**
separate; vgraph only provides the batching.
> A: default choice, we can pivot later if need be, but keeping this package lean is optimal. A separate five07.graphql package could be a good idea

**Q10.** Migrations (your Atlas TODO): inside vgraph, or a separate package (for
example `vmigrate`) that reads vgraph's schema? **Default:** separate.
> A: V ORM now has a migration tool and we should utilize it instead of an Atlas clone. (https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)

**Q11.** Upstream V bugs (`@[index]` on SQLite, `exec` swallowing errors, the
`update` name, `last_insert_rowid`): report or fix them in `vlang/v` as part of this
project, or only work around them? **Default:** report each one with the small
reproduction programs already written, and work around them in the meantime.
> A: like the changes I PR'd for veb/HMR, we'll potentially report issues with a PR ready.

**Q12.** License: MIT, matching `rest-api`? **Default:** MIT.
> A: MIT

### New questions from your answers

**Q13. Q2 and Q10 conflict.** `v.migrations` isn't in the `0.5.2` tag: it landed on
master on 2026-10-10. Your compiler, master `53dd72c`, has it and passes its tests, but
still reports `V 0.5.2`. **Default:** pin to master commit `53dd72c` instead of the tag.
Record it in the README and CI (`git checkout 53dd72c && make`), and bump it on purpose.
The other choice is to stay on the `0.5.2` tag and move Phase 5 until a release
includes `v.migrations`.
> A: let's use whatever master I have checked out for V. By the time we finish building, we will decide to pin on `0.5.X`

**Q14. Where `example/` lives, and what is copied.** **Default:** `vgraph/example/`, with
its own `v.mod` (`name: 'example'`), copied from `rest-api`'s last commit (`9d802d6`)
with `git archive`, which leaves out `.git`. That also leaves out `rest-api`'s
uncommitted `TODO.md` edit, its untracked `VGRAPH.md` (an older copy of this plan),
`PLAN.md` and any `.db` file. The name changes from `rest-api` to `example` in
`v.mod`, `.env.example` (`DB_PATH=example.db`) and the README.
> A: default choice

**Q15. How `example` imports vgraph during Phases 0–1.** A `v.mod` in `example/` makes
`example/` the import root, so it can't see `../load`. **Default:** keep the loader
inside `example/vgraph/load/` until Phase 2. Phase 2 then moves it to the package root
and symlinks `~/.vmodules/five07/vgraph` to this repo, so `example` already imports
`five07.vgraph` before anything is published. Or symlink from day one, which means
renaming nothing later but needs that symlink on every machine and in CI.
> A: default choice

**Q16. How queries are counted for the Phase 1 exit check.** `rest-api` has no SQL
tracing. **Default:** a small `CountingConnection` that wraps `orm.Connection` and
records each statement, used only in tests. Each endpoint test then asserts its query
count, so an N+1 regression fails the test instead of being caught by eye. It can later
become part of vgraph (`vgraph.trace`).
> A: sounds good

**Q17. Query layer: `orm.new_query`, or vgraph's own on `orm.Connection.select`?** Phase 0
found that the function API is deprecated. It leaves vlib after 2027-08-17 for a
separate repository that doesn't exist yet. **Default:** build on `Connection.select`.
vgraph already reflects over every field, the driver interface stays in vlib, and
Postgres/MySQL come with it. The cost is mapping each field type ourselves: options,
`time.Time`, enums, `sql_type` overrides. The spike maps int, i64, f64, bool and string
in about 60 lines (`spike/load/select.v`). The other choice is `new_query` for now,
switching when its new home is known.
> A: default choice

**Q18. Schema source for `vgraph gen`: (a) `edges()` methods or (c) `schema.toml`?** See
the comparison under Phase 3. **Recommendation:** (a). The generator needs the fields
either way, and (a) gets them from the real structs instead of a second copy.
> A: (a) `edges()` methods. *(`schema.toml` and its sync test were then removed.)*

### Phase 4 scope (GraphQL)

Background: vgraph's generated client already loads one query per edge per level,
which is how a GraphQL executor should resolve nested fields. What doesn't exist
yet: a GraphQL schema, a parser, an executor, and an HTTP endpoint.

**Q19. Operations: queries only, or mutations too?** vgraph only reads today.
Mutations need a write API first: create, update and delete, plus writing edges,
including both directions of a bidirectional edge. **Default:** queries only for
Phase 4, with the write API and mutations as a later phase.
> A:

**Q20. Parser and executor: our own, or `luizfonseca.graphql`?** That package is a
parser only, unfinished, and untouched for about 3 years. **Default:** our own: a
lexer and parser for the executable subset of the spec (queries, fields, arguments,
aliases, variables, fragments and inline fragments, `@include` / `@skip`), and an
executor that resolves each level of a query with the generated `with_<edge>` loads.
> A:

**Q21. Schema: generated, or written by hand?** **Default:** generated by `vgraph gen`
(a flag such as `--graphql`, or always), like Ent's `entgql`. Each table becomes an
object type with its scalar fields and its edges as fields, plus root query fields
for each table. The output is both the SDL (`schema.graphql`) and the V resolvers.
Field names stay snake_case (`created_at`), or are converted to camelCase
(`createdAt`) as GraphQL tooling expects.
> A: (and snake_case or camelCase?)

**Q22. Arguments, pagination and counts.** **Default:** list fields take `where`
(one input type per table, built from the same predicates as the generated
queries: `eq`, `lt`/`gt`, `in`, `like`, `is_null`), `order_by` and `limit` /
`offset`, and each table gets a `count`. Relay-style cursor connections
(`edges { node }`, `pageInfo`, as `entgql` does) come later, if needed. The
generated V queries gain `count()` and `offset()` for this.
> A:

**Q23. Introspection.** Tools such as GraphiQL, Apollo and code generators need
`__schema` / `__type`. **Default:** yes: it's mostly static data generated with the
schema, and without it the endpoint is hard to use from standard tools.
> A:

**Q24. Transport and where it lives.** **Default:** a `graphql` module in this repo
(moved to `five07.graphql` later, if needed), with an HTTP handler that any web
framework can call (request body in, JSON out), and a `POST /graphql` route in
`examples/service` built on veb. No subscriptions.
> A:

**Q25. Delete `spike/`?** The `load/` module replaced it, and its tests still run in
every `v test .`. **Default:** delete it; git history keeps it.
> A:
