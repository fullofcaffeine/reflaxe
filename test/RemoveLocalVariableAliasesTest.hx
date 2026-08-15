#if macro
import haxe.macro.Context;
import haxe.macro.Type.TVar;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.preprocessors.implementations.RemoveLocalVariableAliasesImpl;
#end

/**
	Checks that reference aliases are removed only when the source local keeps
	pointing at the same value.
**/
class RemoveLocalVariableAliasesTest {
	#if macro
	/** Registers the alias-preservation assertions after initialization macros finish. **/
	public static function run():Void {
		Context.onAfterInitMacros(execute);
	}

	static function execute():Void {
		assertRebindingPreservesAlias(macro {
			var source = [1];
			var alias = source;
			source = [2];
			Sys.println(alias[0]);
		}, "same-block assignment");
		assertAliasRebindingPreservesAlias();
		assertRebindingPreservesAlias(macro {
			var source = [1];
			var alias = source;
			{
				source = [2];
			}
			Sys.println(alias[0]);
		}, "nested-block assignment");
		assertNestedScopeRebindingPreservesAlias();
		assertRebindingPreservesAlias(macro {
			var source = [1];
			var alias = source;
			if (source.length > 0) {
				source = [2];
			}
			Sys.println(alias[0]);
		}, "branch assignment");
		assertRebindingPreservesAlias(macro {
			var source = [1];
			var alias = source;
			while (source.length == 0) {
				source = [2];
			}
			Sys.println(alias[0]);
		}, "loop assignment");
		assertRebindingPreservesAlias(macro {
			var source = [1];
			var alias = source;
			var replace = function() {
				source = [2];
			};
			replace();
			Sys.println(alias[0]);
		}, "nested-function assignment");
		assertStableAliasIsRemoved();
		assertReferencedValueMutationStillAllowsRemoval();
	}

	/**
		Proves that a nested alias uses the direct-write inventory for its whole
		enclosing function rather than only the nested block.
	**/
	static function assertNestedScopeRebindingPreservesAlias():Void {
		final expression = macro {
			var source = [1];
			{
				var alias = source;
				source = [2];
				Sys.println(alias[0]);
			}
		};
		final typed = Context.typeExpr(expression);
		final alias = findDeclaration(typed, "alias");
		final processed = processBlock(typed);
		if (!hasDeclaration(processed, alias.id) || countLocalOccurrences(processed, alias.id) == 0) {
			Context.fatalError("nested reference alias ignored an enclosing-function reassignment", expression.pos);
		}
	}

	/** Proves that redirecting the alias itself cannot rewrite the source binding. **/
	static function assertAliasRebindingPreservesAlias():Void {
		final expression = macro {
			var source = [1];
			var alias = source;
			alias = [2];
			Sys.println(source[0]);
			Sys.println(alias[0]);
		};
		final typed = Context.typeExpr(expression);
		final source = findDeclaration(typed, "source");
		final alias = findDeclaration(typed, "alias");
		final processed = processBlock(typed);
		if (!hasDeclaration(processed, alias.id)
			|| countLocalOccurrences(processed, alias.id) < 2
			|| countLocalOccurrences(processed, source.id) < 2) {
			Context.fatalError("reassigned alias did not keep a distinct local identity", expression.pos);
		}
	}

	/**
		Proves that both the alias declaration and its later read survive when
		the original local can be redirected to a different reference.
	**/
	static function assertRebindingPreservesAlias(expression:haxe.macro.Expr, scenario:String):Void {
		final typed = Context.typeExpr(expression);
		final alias = findDeclaration(typed, "alias");
		final processed = processBlock(typed);
		if (!hasDeclaration(processed, alias.id) || countLocalOccurrences(processed, alias.id) == 0) {
			Context.fatalError('reference alias was erased after $scenario', expression.pos);
		}
	}

	/** Proves that a reference alias with a stable source binding is still optimized away. **/
	static function assertStableAliasIsRemoved():Void {
		final expression = macro {
			var source = [1];
			var alias = source;
			Sys.println(alias[0]);
		};
		final typed = Context.typeExpr(expression);
		final source = findDeclaration(typed, "source");
		final alias = findDeclaration(typed, "alias");
		final processed = processBlock(typed);
		if (hasDeclaration(processed, alias.id)
			|| countLocalOccurrences(processed, alias.id) != 0
			|| countLocalOccurrences(processed, source.id) == 0) {
			Context.fatalError("stable reference alias was not removed", expression.pos);
		}
	}

	/**
		Proves that changing an array element or object field does not count as
		redirecting the local binding to a different reference.
	**/
	static function assertReferencedValueMutationStillAllowsRemoval():Void {
		final expression = macro {
			var source = [1];
			var alias = source;
			source[0] = 2;
			Sys.println(alias[0]);

			var objectSource = {value: 1};
			var objectAlias = objectSource;
			objectSource.value = 2;
			Sys.println(objectAlias.value);
		};
		final typed = Context.typeExpr(expression);
		final aliases = [findDeclaration(typed, "alias"), findDeclaration(typed, "objectAlias")];
		final processed = processBlock(typed);
		for (alias in aliases) {
			if (hasDeclaration(processed, alias.id) || countLocalOccurrences(processed, alias.id) != 0) {
				Context.fatalError('reference alias ${alias.name} survived a value-only mutation', expression.pos);
			}
		}
	}

	/** Applies the pass to the expression list represented by a typed block. **/
	static function processBlock(expression:TypedExpr):Array<TypedExpr> {
		return RemoveLocalVariableAliasesImpl.process(switch (expression.expr) {
			case TBlock(expressions): expressions;
			case _: [expression];
		});
	}

	/** Finds one local declaration in the typed regression input. **/
	static function findDeclaration(expression:TypedExpr, name:String):TVar {
		var result:Null<TVar> = null;
		function visit(child:TypedExpr):Void {
			switch (child.expr) {
				case TVar(variable, _) if (variable.name == name):
					result = variable;
				case _:
			}
			TypedExprTools.iter(child, visit);
		}
		visit(expression);
		if (result == null) {
			Context.fatalError('missing regression local declaration $name', expression.pos);
		}
		return result;
	}

	/** Reports whether the processed body still declares a specific local identity. **/
	static function hasDeclaration(expressions:Array<TypedExpr>, id:Int):Bool {
		var result = false;
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TVar(variable, _) if (variable.id == id):
					result = true;
				case _:
			}
			TypedExprTools.iter(expression, visit);
		}
		for (expression in expressions) {
			visit(expression);
		}
		return result;
	}

	/**
		Counts typed local occurrences outside declaration sites, including
		assignment targets as well as value reads.
	**/
	static function countLocalOccurrences(expressions:Array<TypedExpr>, id:Int):Int {
		var result = 0;
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TLocal(variable) if (variable.id == id):
					result += 1;
				case _:
			}
			TypedExprTools.iter(expression, visit);
		}
		for (expression in expressions) {
			visit(expression);
		}
		return result;
	}
	#end
}
