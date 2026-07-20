#if macro
import haxe.macro.Context;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.preprocessors.implementations.RemovePureExpressionsImpl;
#end

/** Focused regressions for side-effect and metadata preservation. */
class RemovePureExpressionsTest {
	#if macro
	public static function run():Void {
		assertNestedAssignmentSurvives();
		assertContinuePreservesPriorEffects();
		assertMetadataEnvelopeSurvives();
		assertPureExpressionIsRemoved();
	}

	static function assertNestedAssignmentSurvives():Void {
		final position = Context.currentPos();
		final typed = Context.typeExpr(macro {
			var condition = true;
			var value = 0;
			if (condition) {
				value = 1;
			}
			value;
		});

		function assignmentCount(expression:TypedExpr):Int {
			var count = 0;
			function visit(child:TypedExpr):Void {
				switch (child.expr) {
					case TBinop(OpAssign | OpAssignOp(_), _, _):
						count += 1;
					case _:
				}
				TypedExprTools.iter(child, visit);
			}
			visit(expression);
			return count;
		}

		final before = assignmentCount(typed);
		final processed = RemovePureExpressionsImpl.process(switch (typed.expr) {
			case TBlock(expressions): expressions;
			case _: [typed];
		});
		var after = 0;
		for (expression in processed) {
			after += assignmentCount(expression);
		}
		if (before != 1 || after != before) {
			Context.fatalError('nested assignment count changed from $before to $after', position);
		}
	}

	static function assertContinuePreservesPriorEffects():Void {
		final position = Context.currentPos();
		final typed = Context.typeExpr(macro {
			var value = 0;
			while (value < 1) {
				value += 1;
				continue;
				value += 100;
			}
		});
		final processed = RemovePureExpressionsImpl.process(switch (typed.expr) {
			case TBlock(expressions): expressions;
			case _: [typed];
		});
		var assignments = 0;
		var continues = 0;
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TBinop(OpAssign | OpAssignOp(_), _, _):
					assignments += 1;
				case TContinue:
					continues += 1;
				case _:
			}
			TypedExprTools.iter(expression, visit);
		}
		for (expression in processed) {
			visit(expression);
		}
		if (assignments != 1 || continues != 1) {
			Context.fatalError('continue cleanup retained $assignments assignments and $continues continue nodes', position);
		}
	}

	static function assertMetadataEnvelopeSurvives():Void {
		final position = Context.currentPos();
		final effect = Context.typeExpr(macro Sys.println("effect"));
		final metadata:MetadataEntry = {
			name: ":reflaxeTestSemanticEnvelope",
			params: [],
			pos: position
		};
		final marked:TypedExpr = {
			expr: TMeta(metadata, effect),
			pos: position,
			t: effect.t
		};
		final processed = RemovePureExpressionsImpl.process([marked]);
		switch (processed) {
			case [{expr: TMeta(result, _)}] if (result.name == metadata.name):
			case _:
				Context.fatalError("unknown metadata envelope was removed from an effectful expression", position);
		}
	}

	static function assertPureExpressionIsRemoved():Void {
		final position = Context.currentPos();
		final pure = Context.typeExpr(macro 1 + 2);
		final processed = RemovePureExpressionsImpl.process([pure]);
		if (processed.length != 0) {
			Context.fatalError("pure standalone expression was not removed", position);
		}
	}
	#end
}
