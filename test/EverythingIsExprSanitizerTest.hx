#if macro
import haxe.macro.Context;
import haxe.macro.Type.TVar;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.preprocessors.implementations.everything_is_expr.EverythingIsExprSanitizer;
import reflaxe.preprocessors.implementations.everything_is_expr.EverythingIsExprSanitizer.EverythingIsExprSanitizerOptions;
#end

/**
	Checks that expression normalization preserves Haxe's lazy boolean operators.

	`&&` skips its right side when the left side is false, while `||` skips it
	when the left side is true. The normalizer may turn a block-valued right side
	into temporary assignments, but those assignments must remain inside the
	branch where the source program would execute them.
**/
class EverythingIsExprSanitizerTest {
	#if macro
	/** Registers the focused short-circuit assertions after macro initialization. **/
	public static function run():Void {
		Context.onAfterInitMacros(execute);
	}

	static function execute():Void {
		assertRightSideRemainsGuarded(macro {
			var gate = false;
			var calls = 0;
			while (gate && {
				calls++;
				true;
			}) {}
			calls;
		}, "boolean and");
		assertRightSideRemainsGuarded(macro {
			var gate = true;
			var calls = 0;
			while (gate || {
				calls++;
				false;
			}) {}
			calls;
		}, "boolean or");
	}

	/**
		Proves the right-side mutation is nested below a conditional branch after
		normalization and never appears as an unconditional loop-body statement.
	**/
	static function assertRightSideRemainsGuarded(expression:haxe.macro.Expr, scenario:String):Void {
		final typed = Context.typeExpr(expression);
		final calls = findDeclaration(typed, "calls");
		final options:EverythingIsExprSanitizerOptions = {};
		final processed = new EverythingIsExprSanitizer(typed, options).convertedExpr();
		final loopBody = findLoopBody(processed, expression.pos);
		var guardedMutation = false;
		var unguardedMutation = false;

		function visit(current:TypedExpr, insideConditionalBranch:Bool):Void {
			final mutatesCalls = switch (current.expr) {
				case TUnop(OpIncrement | OpDecrement, _, {expr: TLocal(variable)}) if (variable.id == calls.id): true;
				case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(variable)}, _) if (variable.id == calls.id): true;
				case _: false;
			};
			if (mutatesCalls) {
				if (insideConditionalBranch) {
					guardedMutation = true;
				} else {
					unguardedMutation = true;
				}
			}
			switch (current.expr) {
				case TIf(condition, thenExpression, elseExpression):
					visit(condition, insideConditionalBranch);
					visit(thenExpression, true);
					if (elseExpression != null) {
						visit(elseExpression, true);
					}
				case _:
					TypedExprTools.iter(current, child -> visit(child, insideConditionalBranch));
			}
		}

		visit(loopBody, false);
		if (!guardedMutation || unguardedMutation) {
			Context.fatalError('$scenario normalization moved a short-circuit right-side effect outside its guard', expression.pos);
		}
	}

	/** Finds the local declaration whose mutation is the observable test effect. **/
	static function findDeclaration(expression:TypedExpr, name:String):TVar {
		var result:Null<TVar> = null;
		function visit(current:TypedExpr):Void {
			switch (current.expr) {
				case TVar(variable, _) if (variable.name == name):
					result = variable;
				case _:
			}
			TypedExprTools.iter(current, visit);
		}
		visit(expression);
		if (result == null) {
			Context.fatalError('missing regression local declaration $name', expression.pos);
		}
		return result;
	}

	/** Finds the normalized loop whose body must retain the lazy branch boundary. **/
	static function findLoopBody(expression:TypedExpr, position:haxe.macro.Expr.Position):TypedExpr {
		var result:Null<TypedExpr> = null;
		function visit(current:TypedExpr):Void {
			switch (current.expr) {
				case TWhile(_, body, _) if (result == null):
					result = body;
				case _:
			}
			if (result == null) {
				TypedExprTools.iter(current, visit);
			}
		}
		visit(expression);
		if (result == null) {
			Context.fatalError("short-circuit regression did not produce a typed loop", position);
		}
		return result;
	}
	#end
}
