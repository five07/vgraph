module lib

// `v.migrations` has a struct named `Status`. Importing it is enough.
import v.migrations

// kinds returns what each field of `T` is, as comptime sees it here.
pub fn kinds[T]() []string {
	mut out := []string{}
	$for field in T.fields {
		$if field.typ is $struct {
			out << '${field.name}: struct'
		} $else $if field.typ is $enum {
			out << '${field.name}: enum'
		} $else {
			out << '${field.name}: other'
		}
	}
	return out
}

// status keeps the import used.
pub fn status() migrations.Status {
	return migrations.Status{}
}
