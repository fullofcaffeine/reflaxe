package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.preprocessors.ExpressionPreprocessor;

using reflaxe.preprocessors.ExpressionPreprocessor.ExpressionPreprocessorHelper;

private enum SemanticFamilyStatus {
	Absent;
	Valid(revision:String, artifacts:Array<SemanticArtifactSnapshot>);
	Invalidated(preprocessorId:String, lastValidArtifacts:Array<SemanticArtifactSnapshot>);
}

private class SemanticFamilyState {
	public final family:SemanticArtifactFamily;
	public var status:SemanticFamilyStatus;

	public function new(family:SemanticArtifactFamily, status:SemanticFamilyStatus) {
		this.family = family;
		this.status = status;
	}
}

/**
	Runs expression preprocessors while enforcing target-owned semantic contracts.

	The lifecycle is opt-in. Targets that do not configure it retain the existing
	preprocessor loop. For opted-in targets, every family is checked before and
	after every pass, and invalidated state must be explicitly rebuilt before the
	function reaches target emission.
**/
class SemanticLifecycle {
	final options:SemanticLifecycleOptions;
	final trace:Array<SemanticLifecycleTraceEvent> = [];

	public var pipelineRevision(get, never):String;

	public function new(options:SemanticLifecycleOptions) {
		this.options = options;
		if (options.schemaVersion != SemanticLifecycleOptions.CURRENT_SCHEMA_VERSION) {
			throw new SemanticLifecycleError("reflaxe:unsupported-semantic-lifecycle-schema",
				'Expected lifecycle schema ${SemanticLifecycleOptions.CURRENT_SCHEMA_VERSION}, but the target requested ${options.schemaVersion}.');
		}
		if (options.pipelineRevision.length == 0) {
			throw new SemanticLifecycleError("reflaxe:missing-target-pipeline-revision", "The target pipeline revision must not be empty.");
		}
		final seen:Map<String, Bool> = [];
		for (family in options.families) {
			if (seen.exists(family.id)) {
				throw new SemanticLifecycleError("reflaxe:duplicate-semantic-family", 'Semantic family "${family.id}" was registered more than once.');
			}
			seen.set(family.id, true);
		}
	}

	inline function get_pipelineRevision():String {
		return options.pipelineRevision;
	}

	/** Starts a new program trace without retaining prior request state. **/
	public function beginProgram():Void {
		trace.resize(0);
	}

	/** Returns a copy so inspection cannot mutate lifecycle behavior. **/
	public function getTrace():Array<SemanticLifecycleTraceEvent> {
		return trace.copy();
	}

	/** Applies and validates the configured preprocessor sequence. **/
	public function process(data:ClassFuncData, compiler:BaseCompiler, preprocessors:Array<ExpressionPreprocessor>):Void {
		data.synchronizeBodyRevision();
		final states = [
			for (family in options.families) {
				final artifacts = takeSnapshot(family, data, "initial");
				new SemanticFamilyState(family, artifacts.length == 0 ? Absent : Valid(data.bodyRevision.id, artifacts));
			}
		];

		for (index in 0...preprocessors.length) {
			final preprocessor = preprocessors[index];
			final preprocessorId = '$index:${preprocessor.lifecycleId()}';
			final beforeRevision = data.bodyRevision.id;
			final beforeByFamily:Map<String, Array<SemanticArtifactSnapshot>> = [];
			final actionByFamily:Map<String, SemanticPreprocessorAction> = [];

			for (state in states) {
				final before = takeSnapshot(state.family, data, preprocessorId);
				assertStateStillMatches(state, before, data.bodyRevision.id, preprocessorId);
				final action = state.family.actionFor(preprocessor.lifecycleId());
				if (action == Reject && !isAbsent(state.status, before)) {
					contractError(preprocessorId, state.family.id, 'Reject was declared, but ${before.length} artifact(s) are active.');
				}
				beforeByFamily.set(state.family.id, before);
				actionByFamily.set(state.family.id, action);
				record(data, preprocessorId, "before", state.family.id, action, before);
			}

			preprocessor.process(data, compiler);
			data.synchronizeBodyRevision();

			for (state in states) {
				final family = state.family;
				final before:Array<SemanticArtifactSnapshot> = cast beforeByFamily.get(family.id);
				final after = takeSnapshot(family, data, preprocessorId);
				final action:SemanticPreprocessorAction = cast actionByFamily.get(family.id);
				state.status = applyAction(state, preprocessorId, action, beforeRevision, data.bodyRevision.id, before, after);
				record(data, preprocessorId, "after", family.id, action, after);
			}
		}

		for (state in states) {
			final family = state.family;
			final artifacts = takeSnapshot(family, data, "final");
			switch (state.status) {
				case Absent:
					if (artifacts.length != 0) {
						contractError("final", family.id, "Artifacts appeared without a declared replacing preprocessor.");
					}
				case Valid(revision, expected):
					if (revision != data.bodyRevision.id) {
						throw new SemanticLifecycleError("reflaxe:planned-body-revision-mismatch",
							'Function "${data.id}" family "${family.id}" was validated for body $revision, but emission received ${data.bodyRevision.id}.');
					}
					assertSameArtifacts("final", family.id, expected, artifacts);
				case Invalidated(preprocessorId, _):
					throw new SemanticLifecycleError("reflaxe:semantic-family-invalidated",
						'Function "${data.id}" family "${family.id}" was invalidated by "$preprocessorId" and was not rebuilt before target emission.');
			}

			final finalError = family.validateFinal(data, artifacts);
			if (finalError != null) {
				contractError("final", family.id, finalError);
			}
			record(data, "final", "final", family.id, Preserve, artifacts);
		}
	}

	function applyAction(state:SemanticFamilyState, preprocessorId:String, action:SemanticPreprocessorAction, beforeRevision:String, afterRevision:String,
			before:Array<SemanticArtifactSnapshot>, after:Array<SemanticArtifactSnapshot>):SemanticFamilyStatus {
		final family = state.family;
		return switch (action) {
			case Preserve:
				assertSameArtifacts(preprocessorId, family.id, before, after);
				if (family.binding == ExactBodyRevision && beforeRevision != afterRevision && !isAbsent(state.status, before)) {
					contractError(preprocessorId, family.id,
						'Preserve cannot carry an exact-body artifact from revision $beforeRevision to $afterRevision. Declare Replace or Invalidate.');
				}
				switch (state.status) {
					case Absent: Absent;
					case Valid(_, _): after.length == 0 ? Absent : Valid(afterRevision, after);
					case Invalidated(invalidator, lastValidArtifacts): Invalidated(invalidator, lastValidArtifacts);
				}
			case Replace:
				final logicalBefore = switch (state.status) {
					case Invalidated(_, lastValidArtifacts): lastValidArtifacts;
					case _: before;
				}
				validateReplacement(family, preprocessorId, logicalBefore, after);
				after.length == 0 ? Absent : Valid(afterRevision, after);
			case Invalidate:
				if (isAbsent(state.status, before) && after.length == 0) {
					Absent;
				} else {
					final lastValidArtifacts = switch (state.status) {
						case Valid(_, artifacts): artifacts;
						case Invalidated(_, artifacts): artifacts;
						case Absent: before;
					}
					Invalidated(preprocessorId, lastValidArtifacts);
				}
			case Reject:
				if (after.length != 0) {
					contractError(preprocessorId, family.id, 'Reject was declared, but the pass produced ${after.length} artifact(s).');
				}
				Absent;
		}
	}

	function validateReplacement(family:SemanticArtifactFamily, preprocessorId:String, before:Array<SemanticArtifactSnapshot>,
			after:Array<SemanticArtifactSnapshot>):Void {
		final mappings = family.mapReplacement(preprocessorId, before.copy(), after.copy());
		if (mappings == null) {
			contractError(preprocessorId, family.id, "Replace was declared without an explicit artifact mapping.");
		}

		final beforeIds:Map<String, Bool> = [for (artifact in before) artifact.id => true];
		final afterIds:Map<String, Bool> = [for (artifact in after) artifact.id => true];
		final mappedBefore:Map<String, Bool> = [];
		final mappedAfter:Map<String, Bool> = [];
		final replacementMappings:Array<SemanticArtifactReplacement> = cast mappings;
		for (mapping in replacementMappings) {
			if (mapping.beforeId == null && mapping.afterId == null) {
				contractError(preprocessorId, family.id, "A replacement mapping cannot have two null endpoints.");
			}
			if (mapping.beforeId != null) {
				if (!beforeIds.exists(mapping.beforeId) || mappedBefore.exists(mapping.beforeId)) {
					contractError(preprocessorId, family.id, 'Before artifact "${mapping.beforeId}" is missing or mapped more than once.');
				}
				mappedBefore.set(mapping.beforeId, true);
			}
			if (mapping.afterId != null) {
				if (!afterIds.exists(mapping.afterId) || mappedAfter.exists(mapping.afterId)) {
					contractError(preprocessorId, family.id, 'After artifact "${mapping.afterId}" is missing or mapped more than once.');
				}
				mappedAfter.set(mapping.afterId, true);
			}
		}
		for (id in beforeIds.keys()) {
			if (!mappedBefore.exists(id)) {
				contractError(preprocessorId, family.id, 'Before artifact "$id" has no replacement mapping.');
			}
		}
		for (id in afterIds.keys()) {
			if (!mappedAfter.exists(id)) {
				contractError(preprocessorId, family.id, 'After artifact "$id" has no replacement mapping.');
			}
		}
	}

	function assertStateStillMatches(state:SemanticFamilyState, observed:Array<SemanticArtifactSnapshot>, bodyRevision:String, preprocessorId:String):Void {
		switch (state.status) {
			case Absent:
				if (observed.length != 0) {
					contractError(preprocessorId, state.family.id, "Artifacts changed outside a declared preprocessor boundary.");
				}
			case Valid(revision, expected):
				if (revision != bodyRevision) {
					contractError(preprocessorId, state.family.id,
						'Body revision changed outside a declared preprocessor boundary ($revision -> $bodyRevision).');
				}
				assertSameArtifacts(preprocessorId, state.family.id, expected, observed);
			case Invalidated(_, _):
		}
	}

	function takeSnapshot(family:SemanticArtifactFamily, data:ClassFuncData, boundary:String):Array<SemanticArtifactSnapshot> {
		final artifacts = family.snapshot(data).copy();
		artifacts.sort((a, b) -> Reflect.compare(a.id, b.id));
		var previous:Null<String> = null;
		for (artifact in artifacts) {
			if (artifact.id.length == 0) {
				contractError(boundary, family.id, "Artifact IDs must not be empty.");
			}
			if (previous == artifact.id) {
				contractError(boundary, family.id, 'Artifact ID "${artifact.id}" occurs more than once.');
			}
			previous = artifact.id;
		}
		return artifacts;
	}

	function assertSameArtifacts(preprocessorId:String, familyId:String, expected:Array<SemanticArtifactSnapshot>,
			observed:Array<SemanticArtifactSnapshot>):Void {
		if (expected.length != observed.length) {
			contractError(preprocessorId, familyId, 'Preserve changed the artifact count from ${expected.length} to ${observed.length}.');
		}
		for (index in 0...expected.length) {
			final left = expected[index];
			final right = observed[index];
			if (left.id != right.id || left.fingerprint != right.fingerprint) {
				contractError(preprocessorId, familyId, 'Preserve changed artifact "${left.id}" (${left.fingerprint} -> ${right.id}:${right.fingerprint}).');
			}
		}
	}

	function isAbsent(status:SemanticFamilyStatus, artifacts:Array<SemanticArtifactSnapshot>):Bool {
		return switch (status) {
			case Absent: artifacts.length == 0;
			case _: false;
		}
	}

	function contractError(preprocessorId:String, familyId:String, detail:String):Dynamic {
		throw new SemanticLifecycleError("reflaxe:semantic-contract-violation", 'Preprocessor "$preprocessorId", family "$familyId": $detail');
	}

	function record(data:ClassFuncData, preprocessorId:String, phase:String, familyId:String, action:SemanticPreprocessorAction,
			artifacts:Array<SemanticArtifactSnapshot>):Void {
		if (!options.captureTrace) {
			return;
		}
		trace.push({
			functionId: data.id,
			programRevision: data.programRevision ?? "<unbound>",
			pipelineRevision: options.pipelineRevision,
			preprocessorId: preprocessorId,
			phase: phase,
			bodyRevision: data.bodyRevision.id,
			familyId: familyId,
			action: Std.string(action),
			artifactIds: [for (artifact in artifacts) '${artifact.id}:${artifact.fingerprint}']
		});
	}
}
#end
