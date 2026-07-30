package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
/**
	Immutable identity and revisions for one final target-selected declaration.

	The values contain no Haxe compiler objects. `publicApiRevision` records the
	surface that another declaration may consume, while
	`implementationRevision` conservatively records every observed declaration
	fact, body, position, and source-content revision.
**/
class FinalProgramDeclarationFingerprint {
	public final identity:String;
	public final moduleIdentity:String;
	public final kind:String;
	public final sourceOriginRevision:String;
	public final publicApiRevision:String;
	public final implementationRevision:String;

	public function new(identity:String, moduleIdentity:String, kind:String, sourceOriginRevision:String, publicApiRevision:String,
			implementationRevision:String) {
		this.identity = identity;
		this.moduleIdentity = moduleIdentity;
		this.kind = kind;
		this.sourceOriginRevision = sourceOriginRevision;
		this.publicApiRevision = publicApiRevision;
		this.implementationRevision = implementationRevision;
	}
}
#end
