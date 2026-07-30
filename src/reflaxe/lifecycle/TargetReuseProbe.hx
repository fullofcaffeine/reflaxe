package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
/**
	Immutable result of asking whether target-source replay can be considered.

	`requestRevision` is always deterministic when the target supplies a
	namespace and revision components, even if blockers make the request
	ineligible. An eligible probe does not imply a cache hit: storage, payload,
	transaction, diagnostics, and corruption checks still decide that later.
**/
class TargetReuseProbe {
	public final requestRevision:Null<String>;
	public final eligible:Bool;

	final blockerValues:Array<String>;

	function new(requestRevision:Null<String>, blockers:Array<String>) {
		this.requestRevision = requestRevision;
		blockerValues = blockers.copy();
		eligible = requestRevision != null && blockerValues.length == 0;
	}

	/**
		Composes the generic final-program identity with target-owned revisions.

		Duplicate component names fail closed because they make it unclear which
		value owns that revision domain. Components are sorted by name so target
		map iteration order cannot perturb the request key.
	**/
	public static function build(snapshot:FinalProgramFingerprintSnapshot, targetNamespace:Null<String>, components:Array<TargetReuseRevisionComponent>,
			blockers:Array<String>):TargetReuseProbe {
		final nextBlockers = blockers.copy();
		if (!snapshot.sourceAuthorityComplete)
			nextBlockers.push("reflaxe:incomplete-source-authority");
		if (targetNamespace == null || targetNamespace.length == 0) {
			nextBlockers.push("reflaxe:target-reuse-not-configured");
			return new TargetReuseProbe(null, normalizedBlockers(nextBlockers));
		}

		final sorted = components.copy();
		sorted.sort((left, right) -> Reflect.compare(left.name, right.name));
		final key = new CanonicalFingerprint("reflaxe-target-source-request-v1");
		key.add("target-namespace", targetNamespace);
		key.add("final-program", snapshot.id);
		var previous:Null<String> = null;
		for (component in sorted) {
			if (component.name == previous)
				throw 'Target reuse revision component "${component.name}" was supplied more than once.';
			previous = component.name;
			key.add("component-name", component.name);
			key.add("component-revision", component.revision);
		}
		return new TargetReuseProbe(key.digest(), normalizedBlockers(nextBlockers));
	}

	/** Returns sorted, duplicate-free ineligibility reasons. **/
	public function blockers():Array<String> {
		return blockerValues.copy();
	}

	static function normalizedBlockers(blockers:Array<String>):Array<String> {
		final unique:Map<String, Bool> = [];
		for (blocker in blockers)
			if (blocker != null && blocker.length > 0)
				unique.set(blocker, true);
		final result = [for (blocker in unique.keys()) blocker];
		result.sort(Reflect.compare);
		return result;
	}
}
#end
