package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
/**
	One target-owned input to an exact generated-source request revision.

	Names identify stable revision domains such as target implementation,
	configuration, runtime inputs, or output schema. Values must already be
	non-sensitive exact revisions rather than raw source, defines, or paths.
**/
class TargetReuseRevisionComponent {
	public final name:String;
	public final revision:String;

	public function new(name:String, revision:String) {
		if (name == null || name.length == 0)
			throw "A target reuse revision component requires a non-empty name.";
		if (revision == null || revision.length == 0)
			throw 'Target reuse revision component "$name" requires a non-empty revision.';
		this.name = name;
		this.revision = revision;
	}
}
#end
