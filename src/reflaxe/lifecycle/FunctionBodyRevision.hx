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
	public var digest(get, never):String;
	public var id(get, never):String;

	final expression:Null<TypedExpr>;
	var cachedDigest:Null<String>;

	#if reflaxe_lifecycle_test
	static var digestCallCount:Int = 0;
	#end

	public function new(generation:Int, expression:Null<TypedExpr>, cachedDigest:Null<String> = null) {
		this.generation = generation;
		this.expression = expression;
		this.cachedDigest = cachedDigest;
	}

	/**
		Returns the stable body digest, computing it only when a caller needs it.

		Most structural preprocessors only need the generation counter. Deferring
		the expensive typed-expression rendering avoids rebuilding the same large
		String after every pass while preserving an exact digest for plan sealing,
		tracing, and exact-body analyses.
	**/
	function get_digest():String {
		var result = cachedDigest;
		if (result == null) {
			result = digestExpression(expression);
			cachedDigest = result;
		}
		return result;
	}

	inline function get_id():String {
		return '$generation:$digest';
	}

	/** Creates the first revision for a possibly bodiless function. **/
	public static function initial(expr:Null<TypedExpr>):FunctionBodyRevision {
		return new FunctionBodyRevision(0, expr);
	}

	/** Creates the next revision after an explicit body replacement. **/
	public function next(expr:Null<TypedExpr>):FunctionBodyRevision {
		return new FunctionBodyRevision(generation + 1, expr);
	}

	/**
		Creates a revision only when a preprocessor mutated the existing body in
		place instead of calling `ClassFuncData.setExpr`.
	**/
	public function observe(expr:Null<TypedExpr>):FunctionBodyRevision {
		final observedDigest = digestExpression(expr);
		if (cachedDigest == null) {
			cachedDigest = observedDigest;
			return this;
		}
		return observedDigest == cachedDigest ? this : new FunctionBodyRevision(generation + 1, expr, observedDigest);
	}

	#if reflaxe_lifecycle_test
	/** Resets the deterministic digest counter used by focused lifecycle tests. **/
	public static function resetDigestCallCount():Void {
		digestCallCount = 0;
	}

	/** Returns how often a test compilation rendered and hashed a typed body. **/
	public static function getDigestCallCount():Int {
		return digestCallCount;
	}
	#end

	/**
		Returns a path-independent digest of Haxe's typed-expression rendering.

		Macro hosts use Haxe's canonical typed S-expression. Native Reflaxe hosts
		can provide the same typed-expression objects under `reflaxe_runtime`; the
		fallback still gives request-local change detection until a host-normalized
		digest is supplied by that adapter.
	**/
	public static function digestExpression(expr:Null<TypedExpr>):String {
		#if reflaxe_lifecycle_test
		digestCallCount += 1;
		#end
		if (expr == null) {
			return Sha256.encode("<bodiless>");
		}
		final rendered = #if macro haxe.macro.TypedExprTools.toString(expr) #else Std.string(expr.expr) #end;
		return Sha256.encode(rendered);
	}
}
#end
