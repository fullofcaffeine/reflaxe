package;

/** Retained user code used by the program-fingerprint integration test. **/
@:keep
class ProgramRevisionSubject {
	/** Contains both a local declaration and read whose Haxe IDs can be perturbed. **/
	public static function value():Int {
		var input = 1;
		return input + 1;
	}
}
