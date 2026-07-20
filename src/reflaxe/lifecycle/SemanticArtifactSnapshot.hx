package reflaxe.lifecycle;

/**
	A target-owned opaque semantic artifact visible to the lifecycle validator.

	`id` identifies the artifact within its family. `fingerprint` contains the
	family-specific structural facts that a preserving preprocessor must retain.
	`origin` is diagnostic text only and does not participate in identity.
**/
@:structInit
class SemanticArtifactSnapshot {
	public final id:String;
	public final fingerprint:String;
	public final origin:Null<String>;

	public function new(id:String, fingerprint:String, origin:Null<String> = null) {
		this.id = id;
		this.fingerprint = fingerprint;
		this.origin = origin;
	}
}
