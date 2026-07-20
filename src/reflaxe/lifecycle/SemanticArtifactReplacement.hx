package reflaxe.lifecycle;

/** Maps one artifact identity before a replacing pass to its identity afterward. **/
@:structInit
class SemanticArtifactReplacement {
	public final beforeId:Null<String>;
	public final afterId:Null<String>;

	public function new(beforeId:Null<String>, afterId:Null<String>) {
		this.beforeId = beforeId;
		this.afterId = afterId;
	}
}
