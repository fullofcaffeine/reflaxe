// =======================================================
// * RemoveLocalVariableAliases
// =======================================================
package reflaxe.preprocessors.implementations;

#if (macro || reflaxe_runtime)
import reflaxe.helpers.Context;
import haxe.macro.Type;

using reflaxe.helpers.NameMetaHelper;
using reflaxe.helpers.NullableMetaAccessHelper;
using reflaxe.helpers.NullHelper;
using reflaxe.helpers.TypedExprHelper;
using reflaxe.helpers.TypeHelper;

/**
	Removes unnecessary reference aliases without changing local binding
	semantics.

	A reference alias can disappear only when neither its source local nor the
	alias local is directly reassigned anywhere in the function body. Mutating
	an array element or object field is intentionally not a local reassignment:
	the local still points at the same reference in that case.
**/
class RemoveLocalVariableAliasesImpl {
	public static function process(el:Array<TypedExpr>):Array<TypedExpr> {
		final directlyReboundLocalIds = collectDirectlyReboundLocalIds(el);
		final uvar = new RemoveLocalVariableAliasesImpl(el, directlyReboundLocalIds);
		return uvar.removeAliases();
	}

	// ---
	var el:Array<TypedExpr>;
	var directlyReboundLocalIds:Map<Int, Bool>;
	var aliases:Map<Int, TypedExpr>;

	function new(el:Array<TypedExpr>, directlyReboundLocalIds:Map<Int, Bool>) {
		this.el = el;
		this.directlyReboundLocalIds = directlyReboundLocalIds;
		aliases = [];
	}

	/**
		Builds one conservative inventory for the whole function. This includes
		writes inside branches, loops, nested blocks, and nested functions so an
		alias is never removed based on traversal order.
	**/
	static function collectDirectlyReboundLocalIds(expressions:Array<TypedExpr>):Map<Int, Bool> {
		final result:Map<Int, Bool> = [];
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TBinop(OpAssign | OpAssignOp(_), target, _):
					recordDirectlyReboundLocal(target, result);
				case TUnop(OpIncrement | OpDecrement, _, target):
					recordDirectlyReboundLocal(target, result);
				case _:
			}
			haxe.macro.TypedExprTools.iter(expression, visit);
		}
		for (expression in expressions) {
			visit(expression);
		}
		return result;
	}

	/**
		Records writes to a local binding while deliberately ignoring writes
		through that binding, such as `items[0] = value` or `object.field = value`.
	**/
	static function recordDirectlyReboundLocal(target:TypedExpr, result:Map<Int, Bool>):Void {
		switch (target.expr) {
			case TLocal(variable):
				result.set(variable.id, true);
			case TParenthesis(inner) | TMeta(_, inner) | TCast(inner, _):
				recordDirectlyReboundLocal(inner, result);
			case _:
		}
	}

	/**
		Types that "copy" (like primitives) should not have aliases erased.
	**/
	function isCopyType(t:Type):Bool {
		final innerType = Context.followWithAbstracts(t);
		return switch (innerType) {
			case TAbstract(_.get() => abs, []): abs.hasMeta(":runtimeValue");
			case _ if (innerType.getMeta().maybeHas(":copyValue")): true;
			case _ if (innerType.isString()): true;
			case _: false;
		}
	}

	function removeAliases():Array<TypedExpr> {
		final result:Array<TypedExpr> = [];
		for (expr in el) {
			final skipExpr = switch (expr.expr) {
				case TVar(declTVar, ogVarExpr) if (ogVarExpr != null && !isCopyType(declTVar.t)): {
						switch (ogVarExpr.unwrapUnsafeCasts().expr) {
							case TLocal(tvar): {
									var skip = false;
									// If both variable declarations have the same type, it's okay we ignored unsafe casts
									if (declTVar.t.equals(tvar.t)
										&& !directlyReboundLocalIds.exists(tvar.id)
										&& !directlyReboundLocalIds.exists(declTVar.id)) {
										// might be worth keeping alias if the alias name is significantly smaller?
										final ogNameLen = tvar.name.length;
										final aliasNameLen = declTVar.name.length;
										if (ogNameLen <= aliasNameLen + 10) {
											final newVarExpr = if (aliases.exists(tvar.id)) {
												aliases.get(tvar.id).trustMe();
											} else {
												ogVarExpr.trustMe();
											}
											aliases.set(declTVar.id, newVarExpr);
											skip = true;
										}
									}
									skip; // skip if alias set
								}
							case _: false;
						}
					}
				case TBlock(blockExprs): {
						final blockProcessor = new RemoveLocalVariableAliasesImpl(blockExprs, directlyReboundLocalIds);
						result.push(expr.copy(TBlock(blockProcessor.removeAliases())));
						true; // skip since we supplied our own version of TBlock
					}
				case _: false;
			}

			if (!skipExpr) {
				result.push(expr);
			}
		}

		return result.map(replaceAliases);
	}

	function replaceAliases(e:TypedExpr):TypedExpr {
		switch (e.expr) {
			case TLocal(tvar):
				{
					final newExpr = aliases.get(tvar.id);
					if (newExpr != null) {
						return newExpr;
					}
				}
			case _:
		}
		return haxe.macro.TypedExprTools.map(e, replaceAliases);
	}
}
#end
