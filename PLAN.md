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
5. **GraphQL** (Phase 4): a schema, parser, validator, executor and HTTP handler of
   its own, in a module that can move to `five07.graphql` (Q19–Q24).
6. **Parity with Ent and entgql** (Q19, Q26): every Ent feature is planned. The ones
   vgraph lacks, the write API included, are Phase 6; the inventory is there.

**Non-goals for v1:** a migration engine of its own (Q10: `v.migrations` runs them),
Ent's Gremlin driver and its extensions other than entgql (Q37). Those are listed in
§8 for later.
*(2026-10-13: hooks, privacy and GraphQL execution were non-goals; Q19 and Q26 moved
them into scope.)*

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
  the side without the foreign key; its index is unique (`migration_indexes`, Phase 5).

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
| `graphql` | lexer, parser, validator, executor, introspection, HTTP handler | our own, in a module that never imports vgraph, so it can become `five07.graphql` (Q20, Q24) | 4 |
| `vgraph gen` GraphQL output | the SDL and the V resolvers for every table, batched through the generated client | code generation, like `entgql` (Q21) | 4 |
| migration helpers | turn declared edges into `v.migrations` steps: an index on every edge column, foreign keys, the join tables for many-to-many | helpers that return `migrations.Index` / `ForeignKey` / `Table`; `v.migrations` runs them | 5 (Q10) |
| Ent parity | the write API, transactions, field options, hooks, interceptors, privacy, the rest of Ent's query API, and entgql's generated mutations and connections | the core, `load` and the generator | 6 (Q26) |

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

**Phase 3.2: non-int keys** (Q43). Before GraphQL, because Phase 4's generated
resolvers sit on the load API. `load` keys everything by the key's string form
internally (`map[string]`) and accepts `int`, `i64` and `string` primary and foreign
keys; `Schema.validate` checks that an edge column's type matches its target's key.
The generated client stays typed: `where_id(value string)` on a UUID table. No third
generic key parameter, since generics are where the compiler bugs in `regressions/`
came from. A UUID is a `string` field (`TEXT`, or `uuid` through `sql_type` on
PostgreSQL), as V has no UUID type.
*Exit:* `examples/relations` gains a UUID-keyed table with edges in both directions,
tested on SQLite and PostgreSQL, and everything else passes unchanged.

*Result (2026-10-13, done):*
- **`load`:** keys travel as strings (`load/keys.v`): `key_column` reads an `int`,
  `i64` or `string` key (or an option of one) as its `str()`, `key_type` finds a
  column's type, and `in_keys` turns string keys back into `[]int`, `[]i64` or
  `[]string` for the `IN` query. `load_one` / `load_many` / `load_through`, and
  `Client`'s, return `map[string]`. `link_pairs` takes both columns' key types.
  `in_i64s` is new; `int_column` is gone.
- **Validation:** an edge's column must have the type of the key it holds, and a key
  must be an `int`, `i64` or `string`. `ColumnKind` gained `i64`.
- **Generator:** the generated loads key their maps by `.str()`, join-table reads
  pass both key types, and `i64` columns get `where_<field>_in`. The generated API is
  unchanged for int keys; on a UUID table it is `where_id(value string)`.
- **`examples/relations`:** `devices` is keyed by a UUID (`uuid` on PostgreSQL), with
  edges of every kind to and from it (`test_uuid_keys`). `load_test.v` and
  `vgraph_test.v` cover `i64` and string keys and the new validation.
- **Tests:** all 16 test files pass, and both PostgreSQL tests against PostgreSQL 18.
  `examples/service`'s query counts are unchanged.
- **Compiler bug found:** a third, `regressions/generic_result_map_arg.vv`: a generic
  function returning `![]T`, given an array literal of the wrong element type and
  followed by `.map(...)`, compiles without the type error and segfaults.

**Phase 4: GraphQL.** Without it, vgraph can't serve GraphQL to a client at all:
it has no GraphQL schema, parser or executor, and V's standard library has none.
So it is built here, in this repo, and moved to its own package (`five07.graphql`)
later if that's needed (2026-10-12; revises Q9).

Decisions, from Q19–Q35 (2026-10-13):
- **GraphQL only.** Phase 4 builds on what vgraph does today. The Ent features vgraph
  lacks, the write API included, are Phase 6 (Q26).
- **`graphql/` module:** our own lexer, parser, validator and executor, never
  importing vgraph, so it can move to `five07.graphql` (Q20, Q24). The parser reads
  the whole spec: executable documents, and the type system (SDL), including
  `extend type`, since `vgraph gen` merges hand-written `.graphql` files (Q30, Q33).
- **Schemas follow the spec, as Apollo and graphql-js read and write them** (Q30). The
  generated SDL loads in graphql-js's `buildSchema`, and our parser reads SDL that
  graphql-js prints. Apollo's runtime extras (Sandbox page, error codes, persisted
  queries, Federation) are future state (§8).
- **Validation:** every rule in the spec, tested with cases ported from graphql-js,
  plus a maximum depth and number of selections (Q31).
- **Queries and mutations** (Q19, Q27). The executor runs both, mutations serially.
  Until Phase 6e generates them, the app declares mutations in `.graphql` files and
  writes their resolvers; `examples/service`'s call its stores.
- **Generated schema, entgql's conventions** (Q21, Q28): see "GraphQL naming" below.
- **Arguments:** list fields take `where`, `orderBy` and `limit` / `offset`, and each
  table gets a count. The generated V queries gain `count()` and `offset()`, the only
  additions to vgraph's query API in this phase. Relay connections are Phase 6e (Q22).
- **Hidden fields and tables:** `@[graphql: '-']` on a field or struct (Q29).
- **Batching:** level by level; resolvers receive every parent at once, and the
  generated ones run one load per edge per level. Nested `limit` / `offset` is cut
  per parent in V until 6e moves it into SQL (Q32).
- **Hand-written fields and operations** in `*.graphql` files, merged by `vgraph gen`,
  with resolver stubs in a file it never overwrites (Q33).
- **Transactions:** the HTTP handler takes an optional transaction wrapper; a
  request's mutations then share one transaction (Q34).
- **Introspection** (Q23), and an HTTP handler any framework can call, with
  `POST /graphql` in `examples/service` on veb. No subscriptions (Q24).
- **Cleanup:** delete `spike/` (Q25).

GraphQL naming, from entgql (Q28):
- types are named after the struct (`Article`); fields are the Go-style camelCase
  entgql produces from Ent's field names, so `created_at` is `createdAt` and
  `owner_id` is `ownerID`;
- ids are `ID!`. A foreign key column is a field (`ownerID: ID`), as entgql exposes
  a field that an edge is bound to, and in vgraph every edge column is one;
- edges are fields: unique edges (one_to_one, many_to_one) nullable, the others
  `[T!]!`; polymorphic edges stay separate fields;
- `time.Time` is the `Time` scalar;
- `where: ArticleWhereInput` uses entgql's names: `title`, `titleNEQ`, `titleIn`,
  `titleNotIn`, `titleGT` / `GTE` / `LT` / `LTE`, `titleContains`, `titleHasPrefix`,
  `titleHasSuffix`, `titleIsNil` / `titleNotNil`. Only the ones vgraph can run in
  Phase 4 are generated (`Contains` and the prefix/suffix forms are LIKE patterns);
  `and` / `or` / `not` and `has<Edge>` come with 6b and 6e;
- `orderBy: ArticleOrder` is `{ field: ArticleOrderField!, direction: OrderDirection }`,
  as entgql's; `limit` / `offset` are vgraph's own until connections (6e);
- root fields: one list per table, named as entgql's `QueryField` names it
  (`articles`). One row is read with `articles(where: {id: 3})`. `Node`, `node` and
  `nodes` wait for globally unique ids in 6d (Q42).

Exit (Q35): `examples/service` serves `POST /graphql` beside its REST routes, with a
query or mutation for every REST endpoint, asserting the same selects as REST;
`examples/relations` tests each relationship kind through GraphQL; the parser and
validator pass the graphql-js cases; the introspection result matches a checked-in
copy, and Apollo Sandbox and GraphiQL load the schema (by hand, once); SQLite and
PostgreSQL pass in CI, which also checks the generated schema and resolvers are up to
date.

*Result (2026-10-13, done):*
- **`graphql/`** (`five07.vgraph.graphql`; imports only V's standard library):
  - lexer, parser and printer for the whole language, executable and SDL;
  - schemas built from SDL with extensions, printed as graphql-js prints them, and
    checked with graphql-js's schema validation (`validate_schema`);
  - every validation rule of the spec, graphql-js's recommended
    `MaxIntrospectionDepthRule`, its two custom rules (`NoDeprecatedCustomRule`,
    `NoSchemaIntrospectionCustomRule`, as `no_introspection`), and vgraph's limits
    `max_depth` and `max_selections` (Q31);
  - variable and argument coercion with graphql-js's messages; the five scalars,
    custom scalars (`Scalar`), enums, `@oneOf`;
  - the executor: batched resolvers (`Resolver` gets every parent at a level),
    abstract types, `@skip` / `@include`, null propagation with error paths,
    serial mutations, an optional `Transaction` around a request's mutations;
    subscriptions are refused;
  - introspection, and `introspection_query`;
  - `Server.handle`, GraphQL over HTTP for any framework: POST JSON, GET for
    queries only (405 otherwise), `application/graphql-response+json` with 400 for
    request errors when the client accepts it, else `application/json` and 200.
- **Conformance with graphql-js** (`graphql/testdata/`): its own test suite was run
  with a recorder, and every recorded case matches exactly, messages and locations
  included: 166 lexer cases, 697 parse and print cases, 156 schemas built and
  printed, 439 validation cases and 102 SDL validation cases. The introspection of
  two schemas matches graphql-js's byte for byte. CI checks that graphql-js
  (npm, 16.11.0) builds, validates and prints the generated schemas unchanged.
- **Generator:** `vgraph gen` writes `graph/schema.graphql`, `graph/graphql.v`
  (`Graph.graphql(r Resolvers)`) and, once, `graph/resolvers.v`:
  - types per table with entgql's names; list edges are `[T!]`, as entgql writes
    them without connections, not `[T!]!`;
  - `WhereInput` with entgql's predicate names: `NEQ`, `In`, `NotIn`, `GT`/`GTE`/
    `LT`/`LTE`, `Contains`/`HasPrefix`/`HasSuffix` on strings, `IsNil`/`NotNil`;
  - `Order` / `OrderField` / `OrderDirection` as entgql's;
  - edge resolvers reuse `with_<edge>`; nested `limit` / `offset` cut per parent;
  - `.graphql` files anywhere in the project are merged; problems are reported at
    their file and line;
  - stubs for the fields they add to `Query`, `Mutation` or a generated type, as
    methods of `Resolvers` (gqlgen's pattern: the struct holds what they need);
    fields of the files' own object types use the default resolver.
- **Client and `load`:** `offset()`, `count()`, `not_in_*`, and a fix: a
  many_to_many load now keeps the order of the edge's query (it kept the join
  table's).
- **`examples/service`:** `POST /graphql` and `GET /graphql`; `api.graphql` has a
  mutation for each of the 14 REST endpoints that write, resolved through the same
  stores and comment service; mutations share a SQLite transaction. Tests: each of
  the 15 REST reads has a GraphQL query running the same selects; every mutation,
  with REST's messages; rollback; introspection over HTTP equals graphql-js's.
- **`examples/relations`:** `check_graphql` on SQLite and PostgreSQL.
- **Phase 3.2 and 4 together:** all 18 test files pass (20 with the 2 PostgreSQL
  ones, against PostgreSQL 18).
- **Compiler bugs found:** three more in `regressions/`: `smartcast_array_interpolation.vv`,
  `map_nested_field_name.vv`, `const_loop_var/` (a `for` variable clashing with a
  const of the main module).
- **Not done here:** opening Apollo Sandbox and GraphiQL by hand (Q35). Both read
  the schema through introspection, which matches graphql-js's.
- **Left for Phase 6:** `Contains` / `HasPrefix` / `HasSuffix` are LIKE patterns, so
  `%` and `_` in the value act as wildcards (the ORM has no `ESCAPE`); no
  `EqualFold` / `ContainsFold`, and no `In` on floats and times; `i64` columns are
  `Int`, as in entgql, so values past 32 bits fail.

**Phase 5: migration helpers** for `v.migrations` (Q10): from the declared edges,
produce the indexes, foreign keys and join tables as `migrations.Index` /
`ForeignKey` / `Table` values, for migrations written by hand. `examples/service` moves its
table setup to `v.migrations`. Questions: Q44–Q50, all answered with the defaults
(2026-10-13).

*Result (2026-10-13, done):*
- **`migrate.v`** (imports `v.migrations`): `Schema.migration_indexes()`,
  `foreign_keys()`, `join_table(table, edge)`, and `add_edge_indexes` /
  `remove_edge_indexes` for a migration's `up` and `down`, as Q44–Q46 describe.
  Index names are unchanged (`<table>_<columns>_idx`); foreign keys are
  `<table>_<column>_fkey`. `vgraph.Index`, `Index.sql()`, `Schema.indexes()` and
  `Client.ensure_indexes()` are gone (Q47).
- **Join tables:** each now gets a unique index on its two columns (sorted, so the
  two directions of an edge share it), beside the index on each column. The
  single-column index on the pair's first column is redundant with it; it is kept
  so edge indexes stay as before.
- **Schema:** `Column.sql_type` holds a field's `sql_type` attribute, so a join
  column for a `sql_type: 'uuid'` key is `uuid`.
- **Generator:** `graph.v` has `pub fn schema() !vgraph.Schema`, which
  `Graph.new` calls, so a migration gets the schema without a connection.
- **`examples/service`:** `migrations/` (module `migrations`, importing
  `v.migrations as vm`) has `1 initial`: `create_orm_table` for the four models,
  then `add_edge_indexes(graph.schema())`; `down` drops the tables. `new_app_on`
  migrates `db`, not the counting `conn`. The four `create_tables` are gone, and
  the store tests create their tables themselves. `test_startup_migrates`: two
  startups, `status()` is `1 initial applied`, the five indexes are those
  `ensure_indexes` made, rollback drops everything, and migrate restores it. The
  query-count tests are unchanged.
- **`examples/relations`:** `checks.v` has the same kind of migration, run by
  `migrate` on SQLite and on PostgreSQL (`pg.connect_direct`). The unique-index
  check now also rejects a duplicate join row.
- **Tests:** `vgraph_test.v` covers the indexes, foreign keys (none on polymorphic
  columns), join tables with int and UUID keys, and a migrate and rollback on
  SQLite, where the join table rejects a duplicate pair and an unknown key.
  `pg_test.v` runs the helpers through a migration on PostgreSQL, with
  `add_foreign_key`. All 18 test files pass, and both PostgreSQL tests pass
  against PostgreSQL 18. CI is unchanged and hasn't run (it runs on `main`).
- **Compiler bug found:** a seventh, `regressions/sql_transactional_connection.vv`:
  an `sql` block rejects a value typed `orm.TransactionalConnection`, though it
  embeds `orm.Connection`. `examples/relations` passes the database to `migrate` and
  `seed` separately.
- **Caveat, documented in the README:** a migration that calls `add_edge_indexes`
  with the current schema makes the indexes the edges need *now*. When a later
  migration adds edges, the first one has to list its own indexes instead.

**Phase 6: Ent parity** (Q19, Q26). Everything in Ent and entgql that vgraph doesn't
have yet. The sub-phases are a proposal, in dependency order:
- **6a, writes:** create, bulk create, update, delete, edge writes, transactions,
  field options and validators (Q38, Q39);
- **6b, queries:** the rest of Ent's query API (OR/NOT, edge predicates, query-level
  traversal, `select`, aggregates, locking);
- **6c, runtime:** hooks, interceptors, privacy, and passing a context (Q40, Q41);
- **6d, schema:** more field types, custom id types, globally unique ids (each table's
  ids in their own range, set by the migration helpers) and GraphQL's `Node` with
  them (Q42), edge schemas, mixins, declared indexes, views;
- **6e, entgql:** generated mutations, Relay connections, the full `WhereInput`,
  multi-field ordering and per-parent pagination;
- migration helpers (Phase 5) grow with each sub-phase's schema options (Q36).

Decisions (2026-10-13):
- **Order:** Phase 5 comes first and covers edges; each Phase 6 sub-phase extends the
  migration helpers for what it adds (Q36).
- **Writes** (Q38): generated builders per table, `create()`, `update_one()`,
  `update()`, `delete_one()`, `delete()`, with `set_` / `clear_` / `add_<edge>_ids` /
  `remove_<edge>_ids`. A create runs its insert, `last_id()` and edge writes in one
  transaction, and uses `RETURNING id` on PostgreSQL.
- **Field options** (Q39): an optional `fields()` method beside `edges()`, listing
  only the fields that need options; the rest are inferred. It absorbs
  `@[graphql: '-']` (Q29), which keeps working.
- **Hooks** (Q40): `fn (Article) hooks() []vgraph.Hook`, plus runtime hooks on the
  `Graph`. `examples/service` moves its store logic (validation, slugs, timestamps,
  soft delete) into hooks, and its hand-written GraphQL mutations become generated
  ones.
- **Context** (Q41): `g.with_ctx(ctx)` returns a `Graph` whose queries and writes
  pass `ctx`, a value the app defines (its user, request, and so on), to hooks,
  interceptors and privacy rules. The GraphQL handler sets it per request. Hooks
  depend on it, so 6c's design starts from it.

Inventory (2026-10-13), checked against Ent's docs. "Extra" marks what vgraph has
that Ent doesn't.

| Area | Ent feature | vgraph today | Phase |
|---|---|---|---|
| **Fields** | types: ints of every size, floats, bool, string/text, time, bytes, JSON, enum, UUID, `Other` | `int`, `i64`, `f64`, `bool`, `string`, `time.Time`, and options of these | 6d |
| | `Optional`, `Nillable` | option types are nullable; nothing marks a field optional on create | 6a |
| | `Default`, `DefaultFunc`, `UpdateDefault` | none | 6a |
| | `Immutable`, `Sensitive` | none (Q29 hides fields from GraphQL in Phase 4) | 6a |
| | `Unique`, `StorageKey`, `SchemaType`, `Comment`, `Deprecated` | through V's ORM attributes: `@[unique]`, `@[sql: 'col']`, `sql_type` | 6d |
| | validators: `Validate`, `MinLen`, `MaxLen`, `NotEmpty`, `Match`, `Range`, `Positive` | none | 6a |
| | custom types: `GoType`, `ValueScanner` | none | 6d |
| | id types: `i64`, string (UUID) | `int` only (Q6) | 3.2 (Q43) |
| | id types: custom (`GoType`, `ValueScanner`) | none | 6d |
| **Edges** | `To` / `From` with `Ref` (an edge and its inverse, checked together) | each direction declared on its own, with no link between them | 6d |
| | `Unique`, `Field` (the column holding the key) | the kind and `column` | done |
| | `Required`, `Immutable`, `StorageKey` | none | 6a / 6d |
| | `Through`: edge schemas, join tables with fields of their own | join tables have only the two keys | 6d |
| | — | polymorphic edges, per-edge soft delete (extra) | done |
| **Schema** | declared indexes (fields, edges, unique, partial) | edge columns and join pairs, through the migration helpers | 5 (done) / 6d |
| | mixins (shared fields, edges, hooks) | none; V's embedded structs may serve | 6d |
| | annotations (`entsql`, `entgql`) | `@[table]`; `@[graphql]` in Phase 4 (Q29) | 4 / 6d |
| | views, multiple database schemas | none | 6d |
| **Queries** | predicates `EQ`, `NEQ`, `In`, `NotIn`, `GT`/`GTE`/`LT`/`LTE`, `IsNil`, `NotNil` | all but `NEQ` and `NotIn` generated (`load` has `ne`) | 6b |
| | `Contains`, `HasPrefix`, `HasSuffix`, `EqualFold`, `ContainsFold` | `_like` in the client; GraphQL's `Contains` / `HasPrefix` / `HasSuffix` are LIKE patterns without escaping `%` and `_` | 6b: escaping, and the `Fold` forms |
| | `And`, `Or`, `Not` | AND only | 6b |
| | `Has<Edge>`, `Has<Edge>With` | none | 6b |
| | custom SQL predicates | `where(load.Cond...)`, column conditions only | 6b |
| | order by several fields, by an edge's count or field, nulls first/last | one field | 6b |
| | `Limit`, `Offset` | `limit` | `offset` in 4 |
| | `All`, `First`, `Only`, `IDs`, `FirstID`, `OnlyID`, `Count`, `Exist` | `all`, `first` | `count` in 4; rest 6b |
| | `Select`, `Scan`, `Unique` | none | 6b |
| | `GroupBy`, `Aggregate` (count, sum, min, max, mean) | none | 6b |
| | `Modify`, raw SQL (`sql/modifier`, `sql/execquery`) | none | 6b |
| | `ForUpdate`, `ForShare` (`sql/lock`) | none | 6b |
| | traversal from a query (`users().where_…().query_pets()`) | from a node only | 6b |
| | traversal from a node | `query_<edge>` | done |
| | eager loading, nested and configured (`With<Edge>`) | `with_<edge>` | done |
| | named edges (`WithNamed<Edge>`) | none | 6b |
| | `Edges.<X>OrErr`: "not loaded" told apart from "empty" | option fields and lists | 6b |
| | `entql`, generic filtering at runtime | none | 6b |
| **Writes** | `Create`, `CreateBulk`, `MapCreateBulk` | none | 6a |
| | upsert (`OnConflict`, `UpdateNewValues`, `Ignore`, `DoNothing`) | none | 6a |
| | `Update`, `UpdateOne`, `UpdateOneID`: `Set`, `Add` (increment), `Clear`, `Append` | none | 6a |
| | edge writes: `Add<Edge>IDs`, `Remove<Edge>`, `Clear<Edge>`, `Set<Edge>ID` | none | 6a |
| | `Delete`, `DeleteOne`, `DeleteOneID` | none | 6a |
| | the `Mutation` interface (changed fields, old values) | none | 6a (hooks need it) |
| | transactions: `Tx`, `Commit`, `Rollback`, transaction hooks | none; `orm.TransactionalConnection` exists | 6a |
| **Runtime** | hooks: schema and runtime, `On` / `If` / `Unless` | none | 6c |
| | interceptors: `Intercept`, `Traverse`, soft delete as an interceptor | per-edge `soft_del` | 6c |
| | privacy: policies, rules, viewer context | none | 6c |
| | `context.Context` on every call | none | 6c (Q41) |
| | debug logging of queries | `CountingConnection` in tests; `app/trace.v` in `service` | 6c (`vgraph.trace`, Q16) |
| **Codegen** | `entc` feature flags, external templates, extensions | `vgraph gen`, no options | 6d |
| | `ent describe` | none | 6d (`vgraph describe`) |
| | schema visualization (entviz) | none | §8 |
| **Migrations** | automatic and versioned migrations, diffing through Atlas | versioned through `v.migrations`, written by hand, with vgraph's helpers (Q10) | 5 (done); no diffing |
| **entgql** | schema generation | none | 4 |
| | `Node` interface, global ids, `node` / `nodes` | none | 6d, with globally unique ids (Q42) |
| | `CollectFields`: eager loads from the selection set | none | 4 (Q32) |
| | `WhereInput`: every predicate, `and`/`or`/`not`, `has<Edge>` | the predicates `load` can run, ANDed (Phase 4) | rest 6e |
| | `OrderBy` inputs, multi-field ordering | none | 4 (one field); 6e |
| | Relay connections, cursors, `totalCount`, per-parent pagination | none | 6e (Q22) |
| | mutation inputs (`CreateXInput`, `UpdateXInput`, `SetInput`), generated mutations | none | 6e (needs 6a) |
| | annotations: `Skip`, `Type`, `QueryField`, `RelayConnection`, `Mutations`, `OrderField`, `Directives` | none | 4 (`Skip`, Q29); rest 6e |
| | `Transactioner` (a transaction per request) | none | 4 (Q34) |
| **Other** | Gremlin driver; entproto, entoas/ogent | none | §8 (Q37) |

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
> A: The goal of this project is 1:1 feature parity with Ent. mutations are part of that scope. we also need a GraphQL schema, a parser, an executor, and an HTTP endpoint

**Q20. Parser and executor: our own, or `luizfonseca.graphql`?** That package is a
parser only, unfinished, and untouched for about 3 years. **Default:** our own: a
lexer and parser for the executable subset of the spec (queries, fields, arguments,
aliases, variables, fragments and inline fragments, `@include` / `@skip`), and an
executor that resolves each level of a query with the generated `with_<edge>` loads.
> A: Build our own. it's a hard requirement. But build it into a way that we could extract it into a new package (`five07/graphql`).

**Q21. Schema: generated, or written by hand?** **Default:** generated by `vgraph gen`
(a flag such as `--graphql`, or always), like Ent's `entgql`. Each table becomes an
object type with its scalar fields and its edges as fields, plus root query fields
for each table. The output is both the SDL (`schema.graphql`) and the V resolvers.
Field names stay snake_case (`created_at`), or are converted to camelCase
(`createdAt`) as GraphQL tooling expects.
> A: (and snake_case or camelCase?) generated and camelCase field names

**Q22. Arguments, pagination and counts.** **Default:** list fields take `where`
(one input type per table, built from the same predicates as the generated
queries: `eq`, `lt`/`gt`, `in`, `like`, `is_null`), `order_by` and `limit` /
`offset`, and each table gets a `count`. Relay-style cursor connections
(`edges { node }`, `pageInfo`, as `entgql` does) come later, if needed. The
generated V queries gain `count()` and `offset()` for this.
> A:default choice

**Q23. Introspection.** Tools such as GraphiQL, Apollo and code generators need
`__schema` / `__type`. **Default:** yes: it's mostly static data generated with the
schema, and without it the endpoint is hard to use from standard tools.
> A: yes, and let's try to keep to the Apollo standard

**Q24. Transport and where it lives.** **Default:** a `graphql` module in this repo
(moved to `five07.graphql` later, if needed), with an HTTP handler that any web
framework can call (request body in, JSON out), and a `POST /graphql` route in
`examples/service` built on veb. No subscriptions.
> A: agreed on all points

**Q25. Delete `spike/`?** The `load/` module replaced it, and its tests still run in
every `v test .`. **Default:** delete it; git history keeps it.
> A: yes

### Phase 4: new questions from your answers (2026-10-13)

**Q26. What "1:1 parity with Ent" covers, and what lands in Phase 4.** Q19 made Ent
parity the goal, and vgraph has no write API. Should Phase 4 build the missing Ent
features too? *(The feature table that was here is now the Phase 6 inventory.)*
> A: i didn't mean to infer that the missing Ent functionality must be done in phase 4, in fact, that should be pushed to a new phase. This phase should simply focus on the GraphQL layer and its implementation. Plan for all Ent features AND create a new Phase to address the missing vgraph functionality.
>
> *Done: Phase 4 is GraphQL only, Phase 6 is Ent parity with the full inventory, and
> §3 and the layers table say so. Q27 onward were reframed around it; Q27–Q41 replace
> the earlier Q27–Q37, none of which had answers.*

#### Phase 4 (GraphQL)

**Q27. Mutations before the write API.** Q19 puts mutations in scope, but generating
them (`createArticle`, `updateArticle`) needs Phase 6's write API. **Default:** Phase 4
builds everything a mutation needs except the generated ones: the `Mutation` root type,
serial execution as the spec requires, input object types and variables, and a way for
the app to declare mutations and write their resolvers (Q33). `examples/service`
declares one mutation per REST write endpoint, with resolvers calling its existing
stores, so the validation, slugs and soft deletes it already has stay in one place.
Phase 6e then generates mutations for every table.
> A: agreed

**Q28. GraphQL types and names.** **Default:**
- type names come from the struct (`Article`); the root list field from the table
  (`articles`), plus a single-row field `article(id: ID!)`;
- primary keys are `ID!` (strings on the wire, as the spec and Relay expect);
- `time.Time` is a custom `Time` scalar (RFC 3339), as in entgql;
- every type implements `Node`, with root `node(id: ID!)` and `nodes(ids: [ID!]!)`.
  Ids are only unique per table, so a global id names its type;
- polymorphic edges stay separate fields (`Comment.article`, `Comment.post`). A union
  (`owner: Owner`, `union Owner = Article | Post`) can come in 6e;
- one_to_one and many_to_one edges are nullable object fields, the others `[T!]!`.

Two choices to confirm: are **global ids** base64-encoded, as Relay recommends
(`QXJ0aWNsZToz`), or plain (`Article:3`)? And are **foreign key columns** fields
(`Comment.userId`), or only their edges (`Comment.author`)? entgql leaves them out
unless the edge is bound to the field.
> A: stick with entql standard

**Q29. Hiding tables and fields from GraphQL.** Phase 6's field options include
`Sensitive` and entgql's `Skip`, but Phase 4 already needs a way to keep a field
(a password hash) or a whole table (a join table with a struct) out of the schema.
**Default:** a `@[graphql: '-']` attribute on a field or struct, like `@[json: '-']`.
Phase 6 folds it into the field options (Q39) and keeps the attribute working.
> A: Yes, that is a good annotation choice

**Q30. "The Apollo standard" (Q23).** Which of these did you mean? **Default:** (a) and
(b) in Phase 4, (c) and (d) in Phase 6e or later.
- (a) spec introspection that Apollo Sandbox, Apollo Client codegen and GraphiQL read,
  with descriptions (from the doc comments) and `@deprecated`, plus a `GET /graphql`
  page that opens Sandbox or GraphiQL;
- (b) [GraphQL over HTTP](https://graphql.github.io/graphql-over-http/) responses with
  Apollo Server's error codes in `extensions.code` (`GRAPHQL_PARSE_FAILED`,
  `GRAPHQL_VALIDATION_FAILED`, `BAD_USER_INPUT`, `INTERNAL_SERVER_ERROR`);
- (c) automatic persisted queries (APQ, `extensions.persistedQuery.sha256Hash`);
- (d) Apollo Federation v2 subgraph support (`_service { sdl }`, `_entities`, `@key`),
  so vgraph can sit behind an Apollo Router.
> A: sorry, all of that would be future state. I meant the Apollo standard for generating and parsing schemas.

**Q31. Validation and limits.** The spec has about 30 validation rules (unknown
fields, argument types, fragment cycles, variable usage, and so on). **Default:** all
of them, tested against cases ported from graphql-js's test suite, plus a configurable
maximum query depth and number of selections, since nested queries fan out.
> A: agreed

**Q32. How the executor batches.** entgql reads the whole selection set first
(`CollectFields`) and builds one Ent query with every nested `With<Edge>`. The other
route is level by level: the executor hands each field every parent at once, as a
dataloader does. **Default:** level by level. The `graphql` module's resolvers take a
list of parents, so any backend can batch, and the module never imports vgraph. The
generated resolvers run one `load_one` / `load_many` per edge per level, with that
field's `where` and `orderBy` applied, and aliases of the same edge with different
arguments load separately. `examples/service`'s query-count assertions then cover
GraphQL too. 

Nested `limit` / `offset` (`articles { comments(limit: 3) }`) is per parent, which one
`IN (…)` query can't do without window functions. **Default:** Phase 4 loads the
edge's rows in one query and cuts each parent's list in V: correct, batched, but it
reads every row of the edge. Phase 6e moves it into SQL
(`ROW_NUMBER() OVER (PARTITION BY …)`) where the database supports it.
> A: agree with default

**Q33. Hand-written fields and operations.** Apps need fields the schema doesn't
generate (`Article.url`, a root `me`) and, until 6e, all their mutations (Q27).
**Default:** `vgraph gen` also reads any `*.graphql` files in the project
(`extend type Article { url: String! }`, `extend type Mutation { … }`), merges them
into the schema, and writes resolver stubs for the app to fill in, in a file it never
overwrites, as gqlgen does.
> A: yes, agree

**Q34. Transactions for mutations.** The spec runs a request's mutation fields in
order. vgraph has no transactions until 6a, but `orm.TransactionalConnection` does
(SQLite and PostgreSQL implement it). **Default:** the HTTP handler takes an optional
transaction wrapper; when it's set, all of a request's mutation fields run in one
transaction and any error rolls the request back, as entgql's `Transactioner` does.
`examples/service` sets it. The other choice is one transaction per mutation field,
with partial success reported in `errors`.
> A: yes agree

**Q35. Exit criteria for Phase 4.** **Default:**
- `examples/service` serves `POST /graphql` (and `GET` for Sandbox) beside its REST
  routes, with a query or mutation for every REST endpoint, and its tests assert that
  each GraphQL query runs the same selects as the matching REST endpoint;
- `examples/relations` has a GraphQL test for each relationship kind;
- the parser and validator pass the cases ported from graphql-js;
- the standard introspection query's result matches a checked-in copy, and Apollo
  Sandbox and GraphiQL load the schema (checked by hand once);
- everything passes on SQLite and PostgreSQL in CI, and CI checks that the generated
  schema and resolvers are up to date.
> A: perfect

#### Phase order and scope

**Q36. Phase 5 before Phase 6?** Phase 5 (migration helpers from edges) is small and
doesn't depend on Phase 6. Phase 6 adds schema options (unique fields, defaults,
declared indexes, edge schemas) that migrations then need to cover. **Default:** keep
the order; Phase 5 covers edges, and each Phase 6 sub-phase extends the helpers for
what it adds. The other choice is Phase 6 first, so the migration helpers are written
once against the full schema.
> A: yes that is fine

**Q37. Ent features outside the core.** The inventory covers Ent and entgql. Ent also
has a Gremlin driver (graph databases) and extensions: entproto (protobuf / gRPC),
entoas and ogent (OpenAPI), entviz (schema diagrams). **Default:** out of scope for
v1, listed in §3 as non-goals; `vgraph describe` (a text dump of the schema, like
`ent describe`) is in 6d.
> A: out of scope, but add to a list for future state, especially entproto.

#### Phase 6 (Ent parity): answer before Phase 6 starts

**Q38. The write API's shape.** Generated per table, like Ent's builders:

```v ignore
art := g.articles().create()
	.set_title('V')
	.set_author_id(user.id)  // or .set_author(user_node)
	.add_tag_ids(1, 2)       // writes join rows
	.save()!                 // ArticleNode
g.articles().update_one(art).set_title('W').clear_published_at().remove_tag_ids(2).save()!
g.articles().update().where_user_id(3).set_summary('').exec()! // rows changed
g.articles().delete_one(art.article.id).exec()!
g.articles().delete().where_deleted_at_is_not_null().exec()!
```

Writes go through `orm.Connection.insert` / `update` / `delete`. Reading back a new id
is the risk from §5: `last_id()` races when threads share a connection. **Default:**
this shape; a create runs its insert, `last_id()` and edge writes in one transaction,
uses `RETURNING id` on PostgreSQL, and the docs say a connection isn't to be shared
across threads without a pool.
> A: agreed

**Q39. Field options.** Writes need to know which fields are required on create, have
defaults, can't change, or must stay hidden. Reflection gives only the type and
nullability. **Default:** an optional `fields()` method beside `edges()`, listing only
the fields that need options:

```v ignore
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{name: 'slug', immutable: true},
		vgraph.Field{name: 'created_at', default_now: true, immutable: true},
		vgraph.Field{name: 'updated_at', default_now: true, update_now: true},
		vgraph.Field{name: 'body', validate: fn (v string) ! { ... }},
	]
}
```

Fields not listed are inferred: an option type is optional, `@[sql: serial]` is set by
the database, and every other field is required on create.
> A: sounds good

**Q40. Hooks, and where business logic lives.** `examples/service`'s stores validate,
make slugs, set timestamps and soft-delete. In Ent that logic lives in hooks, so every
write, generated GraphQL mutations included, runs it. **Default:** hooks declared like
edges, `fn (Article) hooks() []vgraph.Hook`, each a function that receives the mutation
and the next step, with `on` (create, update, delete) conditions; runtime hooks
registered on the `Graph`. `examples/service` moves its store logic into hooks and its
GraphQL mutations become generated ones.
> A: yes we want that as hooks

**Q41. Context, for privacy and hooks.** Ent passes a `context.Context` to every call,
which is how privacy rules see the viewer and hooks see the request. vgraph's API has
none. **Default:** `g.with_ctx(ctx)` returns a `Graph` whose queries and writes pass
`ctx` to hooks, interceptors and privacy rules, and the GraphQL handler sets it per
request. Leaving it out keeps the API as it is.
> A: yes, especially with hooks to logic, passing a user defined context is critical

#### Phase 4 follow-up (2026-10-13)

**Q42. `Node` and global ids, given entgql's convention (Q28).** entgql's `node(id: ID!)`
finds a row from its id alone. With integer ids that relies on Ent's globally unique
ids (`sql/globalid`): each table's ids start at its own multiple of 2^32, recorded in
an `ent_types` table, so an id says which table it belongs to. vgraph's tables each
count from 1, so `3` could be an article or a user. **Default:** (a).
- (a) Phase 4 leaves out `Node`, `node` and `nodes`. Clients read one row with
  `articles(where: {id: 3})`. Globally unique ids come in 6d, with the migration
  helpers setting each table's starting id, and `Node` with them.
- (b) Add globally unique ids in Phase 4. Only new tables can start at their range;
  `examples/service`'s existing rows keep their ids, so it needs a data migration.
- (c) `Node` now with type-prefixed ids (`Article:3`, or base64 as Relay suggests),
  which is the Relay convention but not entgql's for integer ids.
> A: my choice is (a)

**Q43. Ids other than `int`, such as UUID strings** (reopens Q6). `load`, `Client`,
`Schema.validate` and the generated client assume `int` keys (`map[int]`, `[]int`,
`int_column`). GraphQL's `ID` is a string on the wire, so the schema doesn't change,
but Phase 4's resolvers would be built on the `int` load API, and generalizing it in
6d would break `load`, the generated client and the resolvers at once.
**Default:** a Phase 3.2 before GraphQL: key by the key's string form inside `load`,
accept `int`, `i64` and `string` keys, check edge column types against target keys,
and keep the generated API typed. Test with a UUID-keyed table in `examples/relations`.
> A: default (2026-10-13)

### Phase 5 (migration helpers): answer before Phase 5 starts

What's there (checked 2026-10-13, V master `53dd72c`): `migrate.v` has `vgraph.Index`,
`Schema.indexes()` and `Client.ensure_indexes()`, used at startup by both examples.
`v.migrations` has `migrations.Index{table, columns, name, unique}`,
`ForeignKey{from_table, column, to_table, primary_key, name, on_delete, on_update}` and
`Table{name, columns, foreign_keys, id, id_name, if_not_exists}`, run through
`Context.add_index` / `add_foreign_key` / `create_table`. Its limits that shape Phase 5:
- `add_index` has no `IF NOT EXISTS`, and names indexes `index_<table>_on_<columns>`
  when no name is given; vgraph's are `<table>_<columns>_idx`;
- on SQLite, `add_foreign_key` returns an error: foreign keys go in `Table.foreign_keys`
  when the table is created, or come from the ORM's `@[references]`, as today;
- `Table` takes one primary key column, so a join table can't have a composite key;
- `migrations.new` needs an `orm.TransactionalConnection`. `sqlite.DB` is one, but
  `examples/service`'s `CountingConnection` isn't; on PostgreSQL it refuses the pool
  that `pg.connect` returns and needs `pg.connect_direct`'s `pg.Conn`.

**Q44. The helpers' API.** **Default:** in the `vgraph` module, from a `Schema`:
- `s.migration_indexes() []migrations.Index`: what `indexes()` returns today, with
  vgraph's names kept, so databases that ran `ensure_indexes` already have them;
- `s.foreign_keys() []migrations.ForeignKey`: one per many_to_one edge and per join
  column; none for polymorphic edges, which point at more than one table;
- `s.join_table(table, edge) !migrations.Table` (Q46);
- `vgraph.add_edge_indexes(mut ctx, s)!` and `remove_edge_indexes(mut ctx, s)!`, for a
  migration's `up` and `down`.

`vgraph.Index` and its `sql()` go, replaced by `migrations.Index`. `vgraph` then imports
`v.migrations`, which no V release has yet (Q13 already accepts that).
> A: accept default

**Q45. Foreign keys on SQLite.** SQLite can't add one to an existing table, and the
examples' tables are created by the ORM, whose `@[references]` already writes them.
**Default:** `foreign_keys()` is for tables created through `ctx.create_table` (put them
in `Table.foreign_keys`) and for `add_foreign_key` on PostgreSQL and MySQL. Models
created with `create_orm_table[T]` keep `@[references]`. `Schema.validate` doesn't
check that a foreign key exists.
> A: accept default

**Q46. Join tables.** vgraph's join tables are structs with their own `id` (`GroupUser`,
`ArticleTag`), and a `Table` can't have a composite key. **Default:** `join_table`
returns a `Table` with an `id`, the two join columns `NOT NULL`, typed from the keys
they hold (`integer`, `bigint`, `text`, or `uuid` on PostgreSQL), and a foreign key to
each side. The pair gets a unique index from `migration_indexes()`, so a pair can't be
stored twice (today nothing stops it). Apps that keep a struct for the join table can
use `create_orm_table[T]` instead and take only the indexes.
> A: accept default

**Q47. `ensure_indexes`.** **Default:** remove it and `vgraph.Index.sql()`: nothing is
published, and both examples move to migrations. Index names stay the same (Q44), so an
existing database only needs its baseline migration recorded, not rerun; the examples'
local `.db` files are simply deleted, as `examples/service`'s README already says to do
after a schema change.
> A: accept default

**Q48. `examples/service` and `examples/relations`.** **Default:**
- `examples/service` gets a `migrations/` module with one migration, `1 initial`:
  `create_orm_table[T]` for its four models in dependency order, then
  `add_edge_indexes`; `down` reverses it. The four `create_tables` functions go.
- `new_app_on` runs `migrate()` on `db` (not on `conn`), so the
  `CountingConnection` counts only what the app runs, and the query-count tests
  don't change.
- `examples/relations` does the same in `checks.v`, on SQLite and PostgreSQL
  (`pg.connect_direct` there).
- The stores' own tests keep their `sql db { create table }` fixtures.
> A: accept default

**Q49. Dialects.** **Default:** the helpers take the dialect from the migration's
`Context`. SQLite and PostgreSQL are tested; MySQL is left untested, as for the rest of
vgraph.
> A: accept default

**Q50. Exit criteria for Phase 5.** **Default:**
- `examples/service` starts from an empty database through `v.migrations` alone;
  `status()` shows `1 initial` applied, and `rollback` then `migrate` again works;
- the indexes it ends up with are the ones `ensure_indexes` made, plus Q46's unique
  pair indexes if that's chosen (compared through `sqlite_master`), and the
  query-count tests are unchanged;
- the helpers have tests for every edge kind, polymorphic and UUID keys included, on
  SQLite and PostgreSQL;
- `ensure_indexes` is gone from the package and both examples, and CI (`v vet`
  included) passes.

A command that writes a migration file (`vgraph migrate new`), or diffs the schema
against the database as Atlas does, stays out (Q10).
> A: accept default

## 8. Future state

Out of scope for v1, kept for later (Q30, Q37):
- **entproto** (protobuf and gRPC services generated from the schema): first in line.
- entoas and ogent (an OpenAPI spec and server generated from the schema).
- entviz (schema diagrams).
- Ent's Gremlin driver (graph databases).
- Apollo's runtime extras: a `GET /graphql` page for Sandbox or GraphiQL, Apollo
  Server's error codes in `extensions.code`, automatic persisted queries, and
  Federation v2 subgraph support (`_service`, `_entities`, `@key`).
