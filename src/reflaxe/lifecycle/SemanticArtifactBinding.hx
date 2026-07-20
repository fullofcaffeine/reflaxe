package reflaxe.lifecycle;

/** Describes how tightly a semantic family is bound to a function body. **/
enum SemanticArtifactBinding {
	/** A structural envelope may survive a declared preserving body rewrite. **/
	StructuralEnvelope;

	/** An analysis or plan is valid only for the exact body revision it inspected. **/
	ExactBodyRevision;
}
