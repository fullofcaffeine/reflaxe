package reflaxe.lifecycle;

/** Opt-in configuration for revisioned semantic artifact validation. **/
@:structInit
class SemanticLifecycleOptions {
	/** Current framework contract schema understood by this Reflaxe revision. **/
	public static inline final CURRENT_SCHEMA_VERSION = 1;

	/** The target-owned artifact families enforced for every function body. **/
	public final families:Array<SemanticArtifactFamily>;

	/** Target-owned revision for preprocessor order, contracts, and plan schema. **/
	public final pipelineRevision:String;

	/** Framework lifecycle contract schema expected by the target. **/
	public final schemaVersion:Int;

	/** Retains deterministic in-memory trace events for inspection and tests. **/
	public final captureTrace:Bool;

	public function new(families:Array<SemanticArtifactFamily>, pipelineRevision:String, captureTrace:Bool = false,
			schemaVersion:Int = CURRENT_SCHEMA_VERSION) {
		this.families = families;
		this.pipelineRevision = pipelineRevision;
		this.schemaVersion = schemaVersion;
		this.captureTrace = captureTrace;
	}
}
