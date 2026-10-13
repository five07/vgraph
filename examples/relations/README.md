# relations

Every relationship kind from [Ent's edge docs](https://entgo.io/docs/schema-edges),
declared with vgraph and loaded through the client that `vgraph gen` wrote into
`graph/`. Each kind has a test in `main_test.v`.

| Ent | Example | vgraph edges (`models/models.v`) |
|-----|---------|----------------------------------|
| O2O two types | a user's card | `User.card`: `one_to_one` to `cards` on `owner_id`; `Card.owner`: `many_to_one` to `users` on `owner_id` |
| O2O same type | a linked list | `Node.next`: `many_to_one` to `nodes` on `next_id`; `Node.prev`: `one_to_one` to `nodes` on `next_id` |
| O2O bidirectional | spouses | `User.spouse`: `many_to_one` to `users` on `spouse_id`, set on both users |
| O2M two types | a user's pets | `User.pets`: `one_to_many` to `pets` on `owner_id`; `Pet.owner`: `many_to_one` |
| O2M same type | a category tree | `Category.children`: `one_to_many` on `parent_id`; `Category.parent`: `many_to_one` |
| M2M two types | groups and users | `Group.users` and `User.groups`: `many_to_many` through `group_users`, columns swapped |
| M2M same type | following and followers | `User.following` and `User.followers`: `many_to_many` through `follows`, columns swapped |
| M2M bidirectional | friends | `User.friends`: `many_to_many` through `friendships`, each friendship stored both ways |

Keys don't have to be ints. `Device` is keyed by a UUID (a `string`, stored as
`uuid` on PostgreSQL) and has an edge of each kind: `Device.owner` (`many_to_one` to
`users`) and `User.devices`, `Device.logins` (`one_to_many` on the string column
`logins.device_id`) and `Login.device`, and `Device.groups` / `Group.devices`
(`many_to_many` through `device_groups`, whose columns are a UUID and an int).
`test_uuid_keys` checks them all, in the same number of queries as int keys.

The same relationships are served over GraphQL by the server `vgraph gen` wrote
(`graph/graphql.v`, schema in `graph/schema.graphql`). `check_graphql` queries each
kind through it, with filters, ordering, per-parent limits, counts and UUID keys,
and checks each query runs one select per edge per level.

The rule behind the table: the side without the foreign key is `one_to_one` or
`one_to_many`, the side with it is `many_to_one`, and a join table makes
`many_to_many`.

vgraph only reads. For a bidirectional edge, the app writes both directions: both
`spouse_id`s, or both friendship rows. `ensure_indexes` gives each `one_to_one`
edge a unique index (`cards.owner_id`, `nodes.next_id`), so the database rejects a
second card for the same user.

```sh
v test .                           # needs this checkout at ~/.vmodules/five07/vgraph
v run ../../cmd/vgraph gen .       # after changing models/models.v
```
