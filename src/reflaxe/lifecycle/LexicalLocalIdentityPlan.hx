package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.macro.Type.TVar;
import haxe.macro.Type.TypedExpr;

/**
	Assigns deterministic identities to the local bindings in one typed body.

	Haxe's `TVar.id` is a process-local allocation number. It remains useful for
	matching reads to declarations while one compiler request is active, but it
	cannot identify semantic artifacts across clean or server compilations. This
	plan replaces that number with an owner-bound structural path before a target
	can publish a body, lowering plan, or diagnostic report.

	The traversal below is deliberately explicit. Its child-role names and array
	indices are part of schema v1, so changing a generic AST iterator cannot
	silently renumber otherwise unchanged locals.
**/
class LexicalLocalIdentityPlan {
	public static inline final SCHEMA_VERSION = 1;

	/** Stable function or body identity that owns every local in this plan. **/
	public final ownerId:String;

	final byHostId:Map<Int, LexicalLocalIdentity>;
	final identitiesById:Map<String, Bool>;
	final ordered:Array<LexicalLocalIdentity>;
	final referencedHostIds:Map<Int, TVar>;

	function new(ownerId:String) {
		if (ownerId.length == 0) {
			throw "[reflaxe:missing-lexical-local-owner] A lexical-local plan requires a stable owner identity.";
		}
		this.ownerId = ownerId;
		byHostId = [];
		identitiesById = [];
		ordered = [];
		referencedHostIds = [];
	}

	/**
		Builds one immutable-by-contract plan for a typed expression.

		`externalLocals` names bindings declared outside `expression`, most
		commonly the arguments of a `ClassFuncData` body. Their array order is
		the source function signature order and is therefore stable.
	**/
	public static function build(ownerId:String, expression:Null<TypedExpr>, externalLocals:Array<TVar> = null):LexicalLocalIdentityPlan {
		final result = new LexicalLocalIdentityPlan(ownerId);
		if (externalLocals != null) {
			for (index => local in externalLocals) {
				result.register(local, "function-argument", 'argument/$index');
			}
		}
		if (expression != null) {
			result.visit(expression, "root");
		}
		result.validateReferences();
		return result;
	}

	/** Returns stable identities in canonical source-structure order. **/
	public function identities():Array<LexicalLocalIdentity> {
		return ordered.copy();
	}

	/**
		Returns the stable identity for a request-local Haxe variable.

		A missing binding is a compiler-contract failure, not a reason to leak the
		host ID into target evidence.
	**/
	public function require(local:TVar):LexicalLocalIdentity {
		final result = byHostId.get(local.id);
		if (result == null) {
			throw '[reflaxe:missing-lexical-local-identity] Local "${local.name}" has no identity under owner "$ownerId".';
		}
		return result;
	}

	/** Resolves a renderer-provided host ID without exposing it in the result. **/
	public function requireHostId(hostId:Int):LexicalLocalIdentity {
		final result = byHostId.get(hostId);
		if (result == null) {
			throw '[reflaxe:missing-lexical-local-identity] A rendered Haxe local has no identity under owner "$ownerId".';
		}
		return result;
	}

	function register(local:TVar, kind:String, path:String):Void {
		if (byHostId.exists(local.id)) {
			throw '[reflaxe:duplicate-lexical-local-binding] Local "${local.name}" was bound more than once under owner "$ownerId".';
		}
		final identity = LexicalLocalIdentity.create(ownerId, kind, path, local.name);
		if (identitiesById.exists(identity.id)) {
			throw '[reflaxe:conflicting-lexical-local-identity] Two local declarations claimed "${identity.id}" under owner "$ownerId".';
		}
		byHostId.set(local.id, identity);
		identitiesById.set(identity.id, true);
		ordered.push(identity);
	}

	function reference(local:TVar):Void {
		referencedHostIds.set(local.id, local);
	}

	function validateReferences():Void {
		for (hostId => local in referencedHostIds) {
			if (!byHostId.exists(hostId)) {
				throw '[reflaxe:missing-lexical-local-identity] Local "${local.name}" is read under owner "$ownerId" but has no declaration or external binding.';
			}
		}
	}

	function visit(expression:TypedExpr, path:String):Void {
		switch (expression.expr) {
			case TConst(_) | TTypeExpr(_) | TBreak | TContinue | TIdent(_):
			case TLocal(local):
				reference(local);
			case TArray(target, index):
				visit(target, child(path, "array-target"));
				visit(index, child(path, "array-index"));
			case TBinop(_, left, right):
				visit(left, child(path, "binary-left"));
				visit(right, child(path, "binary-right"));
			case TField(target, _):
				visit(target, child(path, "field-target"));
			case TParenthesis(inner):
				visit(inner, child(path, "parenthesized"));
			case TObjectDecl(fields):
				for (index => field in fields) {
					visit(field.expr, indexed(path, "object-field", index));
				}
			case TArrayDecl(elements):
				visitArray(elements, path, "array-element");
			case TCall(callee, arguments):
				visit(callee, child(path, "call-callee"));
				visitArray(arguments, path, "call-argument");
			case TNew(_, _, arguments):
				visitArray(arguments, path, "constructor-argument");
			case TUnop(_, _, operand):
				visit(operand, child(path, "unary-operand"));
			case TFunction(func):
				for (index => argument in func.args) {
					final argumentPath = indexed(path, "nested-function-argument", index);
					register(argument.v, "function-argument", argumentPath);
					if (argument.value != null) {
						visit(argument.value, child(argumentPath, "default-value"));
					}
				}
				visit(func.expr, child(path, "nested-function-body"));
			case TVar(local, initializer):
				register(local, "variable", child(path, "variable-binding"));
				if (initializer != null) {
					visit(initializer, child(path, "variable-initializer"));
				}
			case TBlock(expressions):
				visitArray(expressions, path, "block-expression");
			case TFor(local, iterator, body):
				register(local, "for-binding", child(path, "for-binding"));
				visit(iterator, child(path, "for-iterator"));
				visit(body, child(path, "for-body"));
			case TIf(condition, thenBranch, elseBranch):
				visit(condition, child(path, "if-condition"));
				visit(thenBranch, child(path, "if-then"));
				if (elseBranch != null) {
					visit(elseBranch, child(path, "if-else"));
				}
			case TWhile(condition, body, _):
				visit(condition, child(path, "while-condition"));
				visit(body, child(path, "while-body"));
			case TSwitch(subject, cases, defaultCase):
				visit(subject, child(path, "switch-subject"));
				for (caseIndex => switchCase in cases) {
					visitArray(switchCase.values, indexed(path, "switch-case", caseIndex), "value");
					visit(switchCase.expr, child(indexed(path, "switch-case", caseIndex), "body"));
				}
				if (defaultCase != null) {
					visit(defaultCase, child(path, "switch-default"));
				}
			case TTry(body, catches):
				visit(body, child(path, "try-body"));
				for (index => caught in catches) {
					final catchPath = indexed(path, "catch", index);
					register(caught.v, "catch-binding", child(catchPath, "binding"));
					visit(caught.expr, child(catchPath, "body"));
				}
			case TReturn(value):
				if (value != null) {
					visit(value, child(path, "return-value"));
				}
			case TThrow(value):
				visit(value, child(path, "throw-value"));
			case TCast(value, _):
				visit(value, child(path, "cast-value"));
			case TMeta(_, value):
				visit(value, child(path, "metadata-value"));
			case TEnumParameter(value, _, _):
				visit(value, child(path, "enum-parameter-value"));
			case TEnumIndex(value):
				visit(value, child(path, "enum-index-value"));
		}
	}

	function visitArray(expressions:Array<TypedExpr>, path:String, role:String):Void {
		for (index => expression in expressions) {
			visit(expression, indexed(path, role, index));
		}
	}

	static inline function child(path:String, role:String):String {
		return '$path/$role';
	}

	static inline function indexed(path:String, role:String, index:Int):String {
		return '$path/$role:$index';
	}
}

/**
	A stable, host-neutral name for one local declaration.

	The readable fields explain collisions and report changes. `id` is the
	canonical value consumers should bind into revisions.
**/
@:allow(reflaxe.lifecycle.LexicalLocalIdentityPlan)
class LexicalLocalIdentity {
	public final id:String;
	public final ownerId:String;
	public final kind:String;
	public final path:String;
	public final name:String;

	function new(id:String, ownerId:String, kind:String, path:String, name:String) {
		this.id = id;
		this.ownerId = ownerId;
		this.kind = kind;
		this.path = path;
		this.name = name;
	}

	static function create(ownerId:String, kind:String, path:String, name:String):LexicalLocalIdentity {
		final payload = [
			"lexical-local-schema",
			Std.string(LexicalLocalIdentityPlan.SCHEMA_VERSION),
			ownerId,
			kind,
			path,
			name
		].map(encodePart).join("|");
		return new LexicalLocalIdentity('lexical-local-v${LexicalLocalIdentityPlan.SCHEMA_VERSION}:${Sha256.encode(payload)}', ownerId, kind, path, name);
	}

	static inline function encodePart(value:String):String {
		return '${value.length}:$value';
	}
}
#end
