package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;

/**
	Builds deterministic revision inputs without delimiter ambiguity.

	Each label and value is length-prefixed before hashing. Callers may therefore
	record arbitrary source names, metadata text, and define values without two
	different sequences producing the same encoded input through separator
	collisions.
**/
class CanonicalFingerprint {
	final encoded:StringBuf = new StringBuf();

	public function new(schema:String) {
		add("schema", schema);
	}

	/** Adds one labeled value to the fingerprint in caller-defined order. **/
	public function add(label:String, value:String):Void {
		appendPart(label);
		appendPart(value);
	}

	/** Adds one labeled Boolean using a target-independent spelling. **/
	public inline function addBool(label:String, value:Bool):Void {
		add(label, value ? "true" : "false");
	}

	/** Adds one labeled integer using its decimal spelling. **/
	public inline function addInt(label:String, value:Int):Void {
		add(label, Std.string(value));
	}

	/** Returns the SHA-256 revision of every value added so far. **/
	public function digest():String {
		return Sha256.encode(encoded.toString());
	}

	function appendPart(value:String):Void {
		encoded.add(value.length);
		encoded.add(":");
		encoded.add(value);
	}
}
#end
