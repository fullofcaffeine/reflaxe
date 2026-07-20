package reflaxe.lifecycle;

/** One deterministic, path-free semantic lifecycle observation. **/
@:structInit
class SemanticLifecycleTraceEvent {
	public final functionId:String;
	public final programRevision:String;
	public final pipelineRevision:String;
	public final preprocessorId:String;
	public final phase:String;
	public final bodyRevision:String;
	public final familyId:String;
	public final action:String;
	public final artifactIds:Array<String>;

	public function new(functionId:String, programRevision:String, pipelineRevision:String, preprocessorId:String, phase:String, bodyRevision:String,
			familyId:String, action:String, artifactIds:Array<String>) {
		this.functionId = functionId;
		this.programRevision = programRevision;
		this.pipelineRevision = pipelineRevision;
		this.preprocessorId = preprocessorId;
		this.phase = phase;
		this.bodyRevision = bodyRevision;
		this.familyId = familyId;
		this.action = action;
		this.artifactIds = artifactIds;
	}
}
