package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import reflaxe.data.ClassFuncData;

/**
	Target-neutral contract for one target-owned semantic artifact family.

	Reflaxe does not interpret the target's metadata, plans, or analysis. The
	target inventories its own opaque artifacts and declares how every configured
	preprocessor may affect them. This keeps ownership explicit without creating
	a shared cross-target IR.
**/
abstract class SemanticArtifactFamily {
	public final id:String;
	public final binding:SemanticArtifactBinding;

	public function new(id:String, binding:SemanticArtifactBinding) {
		if (id.length == 0) {
			throw "Semantic artifact family IDs must not be empty.";
		}
		this.id = id;
		this.binding = binding;
	}

	/** Returns the family's current artifacts in `data`. **/
	public abstract function snapshot(data:ClassFuncData):Array<SemanticArtifactSnapshot>;

	/** Declares how the named preprocessor may affect this family. **/
	public abstract function actionFor(preprocessorId:String):SemanticPreprocessorAction;

	/**
		Maps every artifact consumed or produced by a `Replace` action.

		Each before and after identity must appear exactly once. Use a `null`
		endpoint for deliberate creation or removal. Returning `null` rejects the
		replacement because it was not explicitly mapped.
	**/
	public function mapReplacement(preprocessorId:String, before:Array<SemanticArtifactSnapshot>,
			after:Array<SemanticArtifactSnapshot>):Null<Array<SemanticArtifactReplacement>> {
		return null;
	}

	/** Performs any family-specific final check after generic lifecycle checks. **/
	public function validateFinal(data:ClassFuncData, artifacts:Array<SemanticArtifactSnapshot>):Null<String> {
		return null;
	}
}
#end
