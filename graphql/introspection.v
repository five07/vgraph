module graphql

// The introspection system: the resolvers of `__schema`, `__type`, and the
// fields of the introspection types, as graphql-js resolves them.

// IntroSchema is the source of a `__Schema` object.
pub struct IntroSchema {}

// IntroType is the source of a `__Type` object: a named type, a list or a
// non-null type.
pub struct IntroType {
pub:
	typ TypeNode
}

// IntroField is the source of a `__Field` object.
pub struct IntroField {
pub:
	field FieldDef
}

// IntroInputValue is the source of an `__InputValue` object.
pub struct IntroInputValue {
pub:
	value InputValueDef
}

// IntroEnumValue is the source of an `__EnumValue` object.
pub struct IntroEnumValue {
pub:
	value EnumValueDef
}

// IntroDirective is the source of a `__Directive` object.
pub struct IntroDirective {
pub:
	directive DirectiveDef
}

fn named_ref(name string) TypeNode {
	return NamedType{
		name: Name{
			value: name
		}
	}
}

fn opt_string(s ?string) Resolved {
	if v := s {
		return Value(v)
	}
	return null
}

fn include_deprecated(info FieldInfo) bool {
	v := info.arg('includeDeprecated')
	return v is bool && v as bool
}

// introspect resolves a field of an introspection type for one parent.
fn introspect(info FieldInfo, source Source) Resolved {
	s := info.schema
	field := info.field_name
	match source {
		IntroSchema {
			return match field {
				'description' {
					opt_string(s.description)
				}
				'types' {
					list(s.type_names.map(obj(IntroType{
						typ: named_ref(it)
					})))
				}
				'queryType' {
					if q := s.query {
						obj(IntroType{
							typ: named_ref(q)
						})
					} else {
						Resolved(null)
					}
				}
				'mutationType' {
					if m := s.mutation {
						obj(IntroType{
							typ: named_ref(m)
						})
					} else {
						Resolved(null)
					}
				}
				'subscriptionType' {
					if m := s.subscription {
						obj(IntroType{
							typ: named_ref(m)
						})
					} else {
						Resolved(null)
					}
				}
				'directives' {
					all := include_deprecated(info)
					list(s.directives.filter(all || it.deprecation_reason == none).map(obj(IntroDirective{
						directive: it
					})))
				}
				else {
					Resolved(null)
				}
			}
		}
		IntroType {
			return introspect_type(info, source.typ, field)
		}
		IntroField {
			f := source.field
			return match field {
				'name' {
					Value(f.name)
				}
				'description' {
					opt_string(f.description)
				}
				'args' {
					all := include_deprecated(info)
					list(f.args.filter(all || it.deprecation_reason == none).map(obj(IntroInputValue{
						value: it
					})))
				}
				'type' {
					obj(IntroType{
						typ: f.typ
					})
				}
				'isDeprecated' {
					Value(f.deprecation_reason != none)
				}
				'deprecationReason' {
					opt_string(f.deprecation_reason)
				}
				else {
					Resolved(null)
				}
			}
		}
		IntroInputValue {
			v := source.value
			return match field {
				'name' {
					Value(v.name)
				}
				'description' {
					opt_string(v.description)
				}
				'type' {
					obj(IntroType{
						typ: v.typ
					})
				}
				'defaultValue' {
					if node := s.ast_from_value(v.default_value, v.typ) {
						Value(print_value(node))
					} else {
						Resolved(null)
					}
				}
				'isDeprecated' {
					Value(v.deprecation_reason != none)
				}
				'deprecationReason' {
					opt_string(v.deprecation_reason)
				}
				else {
					Resolved(null)
				}
			}
		}
		IntroEnumValue {
			v := source.value
			return match field {
				'name' { Value(v.name) }
				'description' { opt_string(v.description) }
				'isDeprecated' { Value(v.deprecation_reason != none) }
				'deprecationReason' { opt_string(v.deprecation_reason) }
				else { Resolved(null) }
			}
		}
		IntroDirective {
			d := source.directive
			return match field {
				'name' {
					Value(d.name)
				}
				'description' {
					opt_string(d.description)
				}
				'isRepeatable' {
					Value(d.repeatable)
				}
				'locations' {
					Value(d.locations.map(Value(it)))
				}
				'args' {
					all := include_deprecated(info)
					list(d.args.filter(all || it.deprecation_reason == none).map(obj(IntroInputValue{
						value: it
					})))
				}
				'isDeprecated' {
					Value(d.deprecation_reason != none)
				}
				'deprecationReason' {
					opt_string(d.deprecation_reason)
				}
				else {
					Resolved(null)
				}
			}
		}
		else {
			return FieldError{
				message: 'No resolver for ${info.parent_type}.${field}.'
			}
		}
	}
}

fn introspect_type(info FieldInfo, t TypeNode, field string) Resolved {
	s := info.schema
	if t is ListType || t is NonNullType {
		inner := if t is ListType { t.typ } else { (t as NonNullType).typ }
		return match field {
			'kind' { Value(if t is ListType { 'LIST' } else { 'NON_NULL' }) }
			'ofType' {
				obj(IntroType{
					typ: inner
				})
			}
			else { Resolved(null) }
		}
	}
	named := s.get_type(t.named().name.value) or { return Resolved(null) }
	all := include_deprecated(info)
	return match field {
		'kind' {
			Value(match named.kind {
				.scalar { 'SCALAR' }
				.object { 'OBJECT' }
				.@interface { 'INTERFACE' }
				.@union { 'UNION' }
				.@enum { 'ENUM' }
				.input_object { 'INPUT_OBJECT' }
			})
		}
		'name' {
			Value(named.name)
		}
		'description' {
			opt_string(named.description)
		}
		'specifiedByURL' {
			if named.kind == .scalar { opt_string(named.specified_by_url) } else { Resolved(null) }
		}
		'fields' {
			if named.kind in [.object, .@interface] {
				list(named.fields.filter(all || it.deprecation_reason == none).map(obj(IntroField{
					field: it
				})))
			} else {
				Resolved(null)
			}
		}
		'interfaces' {
			if named.kind in [.object, .@interface] {
				list(named.interfaces.map(obj(IntroType{
					typ: named_ref(it)
				})))
			} else {
				Resolved(null)
			}
		}
		'possibleTypes' {
			if named.is_abstract() {
				list(s.possible_types(named.name).map(obj(IntroType{
					typ: named_ref(it)
				})))
			} else {
				Resolved(null)
			}
		}
		'enumValues' {
			if named.kind == .@enum {
				list(named.values.filter(all || it.deprecation_reason == none).map(obj(IntroEnumValue{
					value: it
				})))
			} else {
				Resolved(null)
			}
		}
		'inputFields' {
			if named.kind == .input_object {
				list(named.input_fields.filter(all || it.deprecation_reason == none).map(obj(IntroInputValue{
					value: it
				})))
			} else {
				Resolved(null)
			}
		}
		'ofType' {
			Resolved(null)
		}
		'isOneOf' {
			if named.kind == .input_object { Value(named.is_one_of) } else { Resolved(null) }
		}
		else {
			Resolved(null)
		}
	}
}
