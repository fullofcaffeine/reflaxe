package reflaxe.lifecycle;

/** The effect one preprocessor declares for one semantic artifact family. **/
enum SemanticPreprocessorAction {
	/** The artifact inventory and family-defined fingerprints remain unchanged. **/
	Preserve;

	/** The pass deliberately consumes and produces artifacts with an explicit mapping. **/
	Replace;

	/** Existing artifacts or analyses become stale and must be rebuilt later. **/
	Invalidate;

	/** The pass cannot run while this family is active. **/
	Reject;
}
