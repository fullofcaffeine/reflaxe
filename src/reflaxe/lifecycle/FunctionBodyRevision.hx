package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.macro.Type.TypedExpr;

/**
	Identifies one observed version of a function body.

	The digest detects in-place changes while `generation` also records explicit
	root replacement through `ClassFuncData.setExpr`, including structurally
	equivalent replacement. This lets semantic analyses bind to the exact body
	they inspected instead of relying on a function name alone.
**/
class FunctionBodyRevision {
	public final generation:Int;
	public final digest:String;
	public final id:String;

	public function new(generation:Int, digest:String) {
		this.generation = generation;
		this.digest = digest;
		this.id = '$generation:$digest';
	}

	/** Creates the first revision for a possibly bodiless function. **/
	public static function initial(expr:Null<TypedExpr>):FunctionBodyRevision {
		return new FunctionBodyRevision(0, digestExpression(expr));
	}

	/** Creates the next revision after an explicit body replacement. **/
	public function next(expr:Null<TypedExpr>):FunctionBodyRevision {
		return new FunctionBodyRevision(generation + 1, digestExpression(expr));
	}

	/**
		Creates a revision only when a preprocessor mutated the existing body in
		place instead of calling `ClassFuncData.setExpr`.
	**/
	public function observe(expr:Null<TypedExpr>):FunctionBodyRevision {
		final observedDigest = digestExpression(expr);
		return observedDigest == digest ? this : new FunctionBodyRevision(generation + 1, observedDigest);
	}

	/**
		Returns a path-independent digest of Haxe's typed-expression rendering.

		Macro hosts use Haxe's canonical typed S-expression. Native Reflaxe hosts
		can provide the same typed-expression objects under `reflaxe_runtime`; the
		fallback still gives request-local change detection until a host-normalized
		digest is supplied by that adapter.
	**/
	public static function digestExpression(expr:Null<TypedExpr>):String {
		if (expr == null) {
			return Sha256.encode("<bodiless>");
		}
		final rendered = #if macro haxe.macro.TypedExprTools.toString(expr) #else Std.string(expr.expr) #end;
		return Sha256.encode(rendered);
	}
}
#end
