module load

import orm
import time

// Reading rows into structs. A struct's columns are its fields, in order, and
// the fields of the structs it embeds (mixins), in their place, named
// `<Struct>.<field>` as V's ORM names them; arrays and maps are relations, not
// columns. Fields may be `i8` to `u64`, `f32`, `f64`, `bool`,
// `string`, `time.Time`, enums (stored as integers), type aliases of those, and
// options of those but enums and aliases.
//
// The type chains below are long because V has no macros, and calling a
// generic function on a field's type generates C that doesn't compile
// (regressions/comptime_generic_call.vv).

// select_columns returns `T`'s columns (only those `only` names, when it names
// some), and the ORM's type of each, in field order.
fn select_columns[T](only []string) !([]string, []int) {
	mut names := []string{}
	mut types := []int{}
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
			// relations
		} $else $if field.is_embed {
			$for sub in field.typ.fields {
				$if sub.typ is $array || sub.typ is $map {
				} $else {
					name := '${field.name}.${column_name(sub.name, sub.attrs)}'
					if only.len == 0 || name in only {
						names << name

						$if sub.typ is ?i8 || sub.unaliased_typ is i8 {
							types << orm.type_idx['i8']
						} $else $if sub.typ is ?i16 || sub.unaliased_typ is i16 {
							types << orm.type_idx['i16']
						} $else $if sub.typ is ?int || sub.unaliased_typ is int {
							types << orm.type_idx['int']
						} $else $if sub.typ is ?i64 || sub.unaliased_typ is i64 {
							types << orm.type_idx['i64']
						} $else $if sub.typ is ?u8 || sub.unaliased_typ is u8 {
							types << orm.type_idx['u8']
						} $else $if sub.typ is ?u16 || sub.unaliased_typ is u16 {
							// read as an i64: db.pg decodes a u16 cell through a pointer
							// that dangles (regressions/sum_type_deref_cast.vv)
							types << orm.type_idx['i64']
						} $else $if sub.typ is ?u32 || sub.unaliased_typ is u32 {
							// read as an i64: db.pg decodes a u32 cell as 0
							types << orm.type_idx['i64']
						} $else $if sub.typ is ?u64 || sub.unaliased_typ is u64 {
							// read as an i64: db.pg decodes a u64 cell wrongly
							types << orm.type_idx['i64']
						} $else $if sub.typ is ?f32 || sub.unaliased_typ is f32 {
							types << orm.type_idx['f32']
						} $else $if sub.typ is ?f64 || sub.unaliased_typ is f64 {
							types << orm.type_idx['f64']
						} $else $if sub.typ is ?bool || sub.unaliased_typ is bool {
							types << orm.type_idx['bool']
						} $else $if sub.typ is ?string || sub.unaliased_typ is string {
							types << orm.type_string
						} $else $if sub.typ is ?time.Time || sub.unaliased_typ is time.Time {
							types << orm.time_
						} $else $if sub.typ is $enum {
							types << orm.enum_
						} $else {
							return error('`${sub.name}`: vgraph cannot read this field type')
						}
					}
				}
			}
		} $else $if field.typ is $struct && field.unaliased_typ !is time.Time && field.typ !is ?time.Time {
			// a relation
		} $else {
			name := column_name(field.name, field.attrs)
			if only.len == 0 || name in only {
				names << name

				$if field.typ is ?i8 || field.unaliased_typ is i8 {
					types << orm.type_idx['i8']
				} $else $if field.typ is ?i16 || field.unaliased_typ is i16 {
					types << orm.type_idx['i16']
				} $else $if field.typ is ?int || field.unaliased_typ is int {
					types << orm.type_idx['int']
				} $else $if field.typ is ?i64 || field.unaliased_typ is i64 {
					types << orm.type_idx['i64']
				} $else $if field.typ is ?u8 || field.unaliased_typ is u8 {
					types << orm.type_idx['u8']
				} $else $if field.typ is ?u16 || field.unaliased_typ is u16 {
					// read as an i64: db.pg decodes a u16 cell through a pointer
					// that dangles (regressions/sum_type_deref_cast.vv)
					types << orm.type_idx['i64']
				} $else $if field.typ is ?u32 || field.unaliased_typ is u32 {
					// read as an i64: db.pg decodes a u32 cell as 0
					types << orm.type_idx['i64']
				} $else $if field.typ is ?u64 || field.unaliased_typ is u64 {
					// read as an i64: db.pg decodes a u64 cell wrongly
					types << orm.type_idx['i64']
				} $else $if field.typ is ?f32 || field.unaliased_typ is f32 {
					types << orm.type_idx['f32']
				} $else $if field.typ is ?f64 || field.unaliased_typ is f64 {
					types << orm.type_idx['f64']
				} $else $if field.typ is ?bool || field.unaliased_typ is bool {
					types << orm.type_idx['bool']
				} $else $if field.typ is ?string || field.unaliased_typ is string {
					types << orm.type_string
				} $else $if field.typ is ?time.Time || field.unaliased_typ is time.Time {
					types << orm.time_
				} $else $if field.typ is $enum {
					types << orm.enum_
				} $else {
					return error('`${field.name}`: vgraph cannot read this field type')
				}
			}
		}
	}
	return names, types
}

// map_row builds a `T` from the cells of one selected row, in the order of
// `select_columns[T](only)`.
fn map_row[T](row []orm.Primitive, only []string) !T {
	mut value := T{}
	mut i := 0
	$for field in T.fields {
		$if field.typ is $array || field.typ is $map {
		} $else $if field.is_embed {
			$for sub in field.typ.fields {
				$if sub.typ is $array || sub.typ is $map {
				} $else {
					if only.len == 0 || '${field.name}.${column_name(sub.name, sub.attrs)}' in only {
						cell := row[i]
						i++

						$if sub.typ is ?i8 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?i8(none)
							} else {
								?i8(i8(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?i16 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?i16(none)
							} else {
								?i16(i16(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?int {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?int(none)
							} else {
								?int(int(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?i64 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?i64(none)
							} else {
								?i64(i64(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?u8 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?u8(none)
							} else {
								?u8(u8(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?u16 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?u16(none)
							} else {
								?u16(u16(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?u32 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?u32(none)
							} else {
								?u32(u32(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?u64 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?u64(none)
							} else {
								?u64(u64(cell_i64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?f32 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?f32(none)
							} else {
								?f32(f32(cell_f64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?f64 {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?f64(none)
							} else {
								?f64(f64(cell_f64(cell, sub.name)!))
							}
						} $else $if sub.typ is ?bool {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?bool(none)
							} else {
								?bool(cell_bool(cell, sub.name)!)
							}
						} $else $if sub.typ is ?string {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?string(none)
							} else {
								?string(cell_string(cell, sub.name)!)
							}
						} $else $if sub.typ is ?time.Time {
							value.$(field.name).$(sub.name) = if cell is orm.Null {
								?time.Time(none)
							} else {
								?time.Time(cell_time(cell, sub.name)!)
							}
						} $else $if sub.unaliased_typ is i8 {
							value.$(field.name).$(sub.name) = i8(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is i16 {
							value.$(field.name).$(sub.name) = i16(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is int {
							value.$(field.name).$(sub.name) = int(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is i64 {
							value.$(field.name).$(sub.name) = i64(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is u8 {
							value.$(field.name).$(sub.name) = u8(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is u16 {
							value.$(field.name).$(sub.name) = u16(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is u32 {
							value.$(field.name).$(sub.name) = u32(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is u64 {
							value.$(field.name).$(sub.name) = u64(cell_i64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is f32 {
							value.$(field.name).$(sub.name) = f32(cell_f64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is f64 {
							value.$(field.name).$(sub.name) = f64(cell_f64(cell, sub.name)!)
						} $else $if sub.unaliased_typ is bool {
							value.$(field.name).$(sub.name) = cell_bool(cell, sub.name)!
						} $else $if sub.unaliased_typ is string {
							value.$(field.name).$(sub.name) = cell_string(cell, sub.name)!
						} $else $if sub.unaliased_typ is time.Time {
							value.$(field.name).$(sub.name) = cell_time(cell, sub.name)!
						} $else $if sub.typ is $enum {
							value.$(field.name).$(sub.name) = int(cell_i64(cell, sub.name)!)
						} $else {
							return error('`${sub.name}`: vgraph cannot read this field type')
						}
					}
				}
			}
		} $else $if field.typ is $struct && field.unaliased_typ !is time.Time && field.typ !is ?time.Time {
		} $else {
			if only.len == 0 || column_name(field.name, field.attrs) in only {
				cell := row[i]
				i++

				$if field.typ is ?i8 {
					value.$(field.name) = if cell is orm.Null {
						?i8(none)
					} else {
						?i8(i8(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?i16 {
					value.$(field.name) = if cell is orm.Null {
						?i16(none)
					} else {
						?i16(i16(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?int {
					value.$(field.name) = if cell is orm.Null {
						?int(none)
					} else {
						?int(int(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?i64 {
					value.$(field.name) = if cell is orm.Null {
						?i64(none)
					} else {
						?i64(i64(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?u8 {
					value.$(field.name) = if cell is orm.Null {
						?u8(none)
					} else {
						?u8(u8(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?u16 {
					value.$(field.name) = if cell is orm.Null {
						?u16(none)
					} else {
						?u16(u16(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?u32 {
					value.$(field.name) = if cell is orm.Null {
						?u32(none)
					} else {
						?u32(u32(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?u64 {
					value.$(field.name) = if cell is orm.Null {
						?u64(none)
					} else {
						?u64(u64(cell_i64(cell, field.name)!))
					}
				} $else $if field.typ is ?f32 {
					value.$(field.name) = if cell is orm.Null {
						?f32(none)
					} else {
						?f32(f32(cell_f64(cell, field.name)!))
					}
				} $else $if field.typ is ?f64 {
					value.$(field.name) = if cell is orm.Null {
						?f64(none)
					} else {
						?f64(f64(cell_f64(cell, field.name)!))
					}
				} $else $if field.typ is ?bool {
					value.$(field.name) = if cell is orm.Null {
						?bool(none)
					} else {
						?bool(cell_bool(cell, field.name)!)
					}
				} $else $if field.typ is ?string {
					value.$(field.name) = if cell is orm.Null {
						?string(none)
					} else {
						?string(cell_string(cell, field.name)!)
					}
				} $else $if field.typ is ?time.Time {
					value.$(field.name) = if cell is orm.Null {
						?time.Time(none)
					} else {
						?time.Time(cell_time(cell, field.name)!)
					}
				} $else $if field.unaliased_typ is i8 {
					value.$(field.name) = i8(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is i16 {
					value.$(field.name) = i16(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is int {
					value.$(field.name) = int(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is i64 {
					value.$(field.name) = i64(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is u8 {
					value.$(field.name) = u8(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is u16 {
					value.$(field.name) = u16(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is u32 {
					value.$(field.name) = u32(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is u64 {
					value.$(field.name) = u64(cell_i64(cell, field.name)!)
				} $else $if field.unaliased_typ is f32 {
					value.$(field.name) = f32(cell_f64(cell, field.name)!)
				} $else $if field.unaliased_typ is f64 {
					value.$(field.name) = f64(cell_f64(cell, field.name)!)
				} $else $if field.unaliased_typ is bool {
					value.$(field.name) = cell_bool(cell, field.name)!
				} $else $if field.unaliased_typ is string {
					value.$(field.name) = cell_string(cell, field.name)!
				} $else $if field.unaliased_typ is time.Time {
					value.$(field.name) = cell_time(cell, field.name)!
				} $else $if field.typ is $enum {
					value.$(field.name) = int(cell_i64(cell, field.name)!)
				} $else {
					return error('`${field.name}`: vgraph cannot read this field type')
				}
			}
		}
	}
	return value
}

fn cell_i64(cell orm.Primitive, name string) !i64 {
	return match cell {
		i8 { i64(cell) }
		i16 { i64(cell) }
		int { i64(cell) }
		i64 { cell }
		u8 { i64(cell) }
		u16 { i64(cell) }
		u32 { i64(cell) }
		u64 { i64(cell) }
		bool {
			if cell { i64(1) } else { i64(0) }
		}
		string { cell.i64() }
		else { error('`${name}`: expected an integer, got ${cell.type_name()}') }
	}
}

fn cell_int(cell orm.Primitive, name string) !int {
	return int(cell_i64(cell, name)!)
}

fn cell_f64(cell orm.Primitive, name string) !f64 {
	return match cell {
		f32 { f64(cell) }
		f64 { cell }
		string { cell.f64() }
		else { f64(cell_i64(cell, name)!) }
	}
}

fn cell_bool(cell orm.Primitive, name string) !bool {
	return match cell {
		bool { cell }
		string { cell in ['1', 't', 'true'] }
		else { cell_i64(cell, name)! != 0 }
	}
}

fn cell_string(cell orm.Primitive, name string) !string {
	return match cell {
		string { cell }
		else { error('`${name}`: expected a string, got ${cell.type_name()}') }
	}
}

fn cell_time(cell orm.Primitive, name string) !time.Time {
	return match cell {
		time.Time { cell }
		else { time.unix(cell_i64(cell, name)!) }
	}
}

// key_type returns the type of `T`'s field stored in `column`, which must be an
// `int`, `i64` or `string`, an alias of one, or an option of one.
pub fn key_type[T](column string) !KeyType {
	$for field in T.fields {
		$if field.is_embed {
			$for sub in field.typ.fields {
				if '${field.name}.${column_name(sub.name, sub.attrs)}' == column {
					$if sub.typ is ?int || sub.unaliased_typ is int {
						return .int
					} $else $if sub.typ is ?i64 || sub.unaliased_typ is i64 {
						return .i64
					} $else $if sub.typ is ?string || sub.unaliased_typ is string {
						return .string
					}
				}
			}
		} $else {
			if column_name(field.name, field.attrs) == column {
				$if field.typ is ?int || field.unaliased_typ is int {
					return .int
				} $else $if field.typ is ?i64 || field.unaliased_typ is i64 {
					return .i64
				} $else $if field.typ is ?string || field.unaliased_typ is string {
					return .string
				}
			}
		}
	}
	return error('`${table_name[T]()}.${column}` is not an int, i64 or string column')
}

// key_column returns the value of `row`'s key field stored in `column` (an
// `int`, `i64` or `string`, an alias of one, or an option of one) as a string.
// It returns `none` when there is no such field, or it is null.
pub fn key_column[T](row T, column string) ?string {
	$for field in T.fields {
		$if field.is_embed {
			$for sub in field.typ.fields {
				if '${field.name}.${column_name(sub.name, sub.attrs)}' == column {
					$if sub.typ is ?int || sub.typ is ?i64 || sub.typ is ?string {
						if v := row.$(field.name).$(sub.name) {
							return v.str()
						}
						return none
					} $else $if sub.unaliased_typ is int || sub.unaliased_typ is i64 {
						return row.$(field.name).$(sub.name).str()
					} $else $if sub.unaliased_typ is string {
						return string(row.$(field.name).$(sub.name))
					}
				}
			}
		} $else {
			if column_name(field.name, field.attrs) == column {
				$if field.typ is ?int || field.typ is ?i64 || field.typ is ?string {
					if v := row.$(field.name) {
						return v.str()
					}
					return none
				} $else $if field.unaliased_typ is int || field.unaliased_typ is i64 {
					return i64(row.$(field.name)).str()
				} $else $if field.unaliased_typ is string {
					return string(row.$(field.name))
				}
			}
		}
	}
	return none
}

// string_column returns the value of the `string` field of `row` stored in
// `column`, or `none` when there is no such field.
pub fn string_column[T](row T, column string) ?string {
	$for field in T.fields {
		$if field.is_embed {
			$for sub in field.typ.fields {
				$if sub.unaliased_typ is string {
					if '${field.name}.${column_name(sub.name, sub.attrs)}' == column {
						return string(row.$(field.name).$(sub.name))
					}
				}
			}
		} $else $if field.unaliased_typ is string {
			if column_name(field.name, field.attrs) == column {
				return string(row.$(field.name))
			}
		}
	}
	return none
}
