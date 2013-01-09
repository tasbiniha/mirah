package org.mirah.jvm.types;

public enum MemberKind {
	MATH_OP,
	COMPARISON_OP,
	METHOD,
	STATIC_METHOD,
	FIELD_ACCESS,
	STATIC_FIELD_ACCESS,
	FIELD_ASSIGN,
	STATIC_FIELD_ASSIGN,
	CONSTRUCTOR,
	STATIC_INITIALIZER,
	ARRAY_ACCESS,
	ARRAY_ASSIGN,
	ARRAY_LENGTH,
	CLASS_LITERAL,
	INSTANCEOF
}