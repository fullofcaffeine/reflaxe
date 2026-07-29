#if macro
import haxe.macro.Context;
import haxe.macro.Type.TVar;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.preprocessors.implementations.RemoveReassignedVariableDeclarationsImpl;
#end

/**
	Checks that declaration removal preserves values read by later initializers.
**/
class RemoveReassignedVariableDeclarationsTest {
	#if macro
	/** Registers declaration-preservation assertions after initialization macros finish. **/
	public static function run():Void {
		Context.onAfterInitMacros(execute);
	}

	static function execute():Void {
		assertReadPreservesDeclaration(macro {
			var value:Null<Int> = null;
			var rendered = Std.string(value);
			value = 1;
			rendered;
		}, "same-block initializer");
		assertReadPreservesDeclaration(macro {
			var value:Null<Int> = null;
			{
				var rendered = Std.string(value);
				rendered;
			}
			value = 1;
		}, "nested-block initializer");
	}

	/**
		Proves that reading a local before its later reassignment keeps the
		original declaration that supplies the observed value.
	**/
	static function assertReadPreservesDeclaration(expression:haxe.macro.Expr, scenario:String):Void {
		final typed = Context.typeExpr(expression);
		final value = findDeclaration(typed, "value");
		final processed = processBlock(typed);
		if (!hasDeclaration(processed, value.id)) {
			Context.fatalError('a local read by a $scenario lost its declaration', expression.pos);
		}
	}

	/** Applies the pass to the expression list represented by a typed block. **/
	static function processBlock(expression:TypedExpr):Array<TypedExpr> {
		return RemoveReassignedVariableDeclarationsImpl.process(switch (expression.expr) {
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
	#end
}
