#if macro
import haxe.macro.Context;
import haxe.crypto.Sha256;
import haxe.macro.Type;
import haxe.macro.TypedExprTools;
import reflaxe.lifecycle.LexicalLocalIdentityPlan;
import reflaxe.lifecycle.NormalizedProgramBodyDigest;

/** Keeps every non-ID character intact when the body normalizer copies text in blocks. */
class ProgramBodyNormalizationTest {
	public static function run():Void {
		Context.onAfterInitMacros(execute);
	}

	/** Typed-expression APIs become available after initialization macros finish. */
	static function execute():Void {
		final body = Context.typeExpr(macro {
			var value = 1;
			final nested = function(value:String):String {
				return value;
			};
			nested("é🙂");
			value;
		});
		var binding:Null<TVar> = null;
		function find(expression:TypedExpr):Void {
			switch expression.expr {
				case TVar(local, _) if (binding == null):
					binding = local;
				case _:
			}
			TypedExprTools.iter(expression, find);
		}
		find(body);
		if (binding == null)
			throw "Expected local binding";
		final plan = LexicalLocalIdentityPlan.build("normalizer-text-test-é🙂", body);
		// Expected IDs retain the previous public string-hash contract. A non-ASCII
		// owner also catches accidental substitution of a different byte encoding.
		for (identity in plan.identities()) {
			final payload = [
				"lexical-local-schema",
				"1",
				identity.ownerId,
				identity.kind,
				identity.path,
				identity.name
			];
			final expected = "lexical-local-v1:" + Sha256.encode(payload.map(value -> '${value.length}:$value').join("|"));
			if (identity.id != expected)
				throw "Local identity digest bytes changed";
		}
		for (identity in plan.functionOccurrences()) {
			final payload = ["lexical-function-occurrence-schema", "1", identity.ownerId, identity.path];
			final expected = "lexical-function-occurrence-v1:" + Sha256.encode(payload.map(value -> '${value.length}:$value').join("|"));
			if (identity.id != expected)
				throw "Function identity digest bytes changed";
		}
		final host = Std.string(binding.id);
		final stable = plan.requireHostId(binding.id).id;
		final token = '[Local value($host):Int]';
		final replacement = '[Local value($stable):Int]';
		final quoted = '"[Local value($host):Int]"';
		final escaped = '"escaped\\\" $token"';
		final padding = StringTools.lpad("", " ", 16384);
		final cases = [
			{input: "", expected: "", count: 0},
			{input: "plain é🙂 text", expected: "plain é🙂 text", count: 0},
			{input: "[unknown]", expected: "[unknown]", count: 0},
			{input: "[Local value(nope):Int]", expected: "[Local value(nope):Int]", count: 0},
			{input: quoted, expected: quoted, count: 0},
			{input: escaped, expected: escaped, count: 0},
			{input: '"unterminated $token', expected: '"unterminated $token', count: 0},
			{input: token, expected: replacement, count: 1},
			{input: 'before $token after', expected: 'before $replacement after', count: 1},
			{input: token + token, expected: replacement + replacement, count: 2},
			{input: padding + token + padding, expected: padding + replacement + padding, count: 1},
			{input: 'é🙂 $quoted $token $quoted $token', expected: 'é🙂 $quoted $replacement $quoted $replacement', count: 2},
			{input: '$escaped $token', expected: '$escaped $replacement', count: 1},
			{input: '"slashes\\\\" $token', expected: '"slashes\\\\" $replacement', count: 1}
		];
		for (index => entry in cases) {
			final actual = @:privateAccess NormalizedProgramBodyDigest.normalizeLocalIds(entry.input, plan);
			if (actual.rendered != entry.expected || actual.occurrenceCount != entry.count)
				throw 'Body normalization changed text or occurrence count in case $index';
		}
		Sys.println('PROGRAM_BODY_NORMALIZATION:PASS cases=${cases.length}');
	}
}
#end
