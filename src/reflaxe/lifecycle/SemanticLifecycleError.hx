package reflaxe.lifecycle;

/** Stable framework error raised before target emission when lifecycle ownership fails. **/
class SemanticLifecycleError extends haxe.Exception {
	public final code:String;

	public function new(code:String, detail:String) {
		this.code = code;
		super('$code: $detail');
	}
}
