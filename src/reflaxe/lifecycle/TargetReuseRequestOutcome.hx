package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
/**
	Describes how one target-reuse-aware compiler request finished.

	Targets use this only to publish or discard a staged immutable cache
	candidate after all requested work, including post-publication native work,
	has completed. It does not grant access to compiler state or output paths.
**/
enum TargetReuseRequestOutcome {
	/** The ordinary target compiler ran and the complete request succeeded. **/
	CompiledMiss;

	/** An exact immutable payload was replayed and the complete request succeeded. **/
	ExactHit;

	/** The request failed before its declared success boundary. **/
	Failed;
}
#end
