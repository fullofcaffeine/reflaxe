#if macro
import haxe.macro.Context;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.ExprTools;
import haxe.macro.Type.ClassField;
import haxe.macro.Type.ClassType;
import haxe.macro.Type.MetaAccess;
import haxe.macro.Type.ModuleType;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import haxe.io.Path;
import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.helpers.ClassFieldHelper;
import reflaxe.lifecycle.CompleteProgramTypeCapture;
import reflaxe.lifecycle.FunctionBodyRevision;
import reflaxe.lifecycle.CanonicalFingerprint;
import reflaxe.lifecycle.FinalProgramFingerprintSnapshot;
import reflaxe.lifecycle.LexicalLocalIdentityPlan;
import reflaxe.lifecycle.MacroSha256;
import reflaxe.lifecycle.NormalizedProgramBodyDigest;
import reflaxe.lifecycle.ProgramRevision;
import reflaxe.lifecycle.ReflaxeImplementationRevision;
import reflaxe.lifecycle.SemanticArtifactBinding;
import reflaxe.lifecycle.SemanticArtifactFamily;
import reflaxe.lifecycle.SemanticArtifactReplacement;
import reflaxe.lifecycle.SemanticArtifactSnapshot;
import reflaxe.lifecycle.SemanticLifecycle;
import reflaxe.lifecycle.SemanticLifecycleError;
import reflaxe.lifecycle.SemanticPreprocessorAction;
import reflaxe.lifecycle.TargetReuseProbe;
import reflaxe.lifecycle.TargetReuseRevisionComponent;
import reflaxe.output.DirectoryOutputTransaction;
import reflaxe.preprocessors.BasePreprocessor;
import reflaxe.preprocessors.ExpressionPreprocessor;
import sys.FileSystem;
import sys.io.File;

using reflaxe.helpers.ClassFieldHelper;
using reflaxe.helpers.ModuleTypeHelper;
#end

/** Focused framework regressions for revisioned semantic preprocessing. **/
class SemanticLifecycleTest {
	#if macro
	/** Registers lifecycle assertions after initialization macros finish. **/
	public static function run():Void {
		Context.onAfterInitMacros(() -> {
			// Load the public Access type so Haxe also supplies its private
			// dot-resolution abstracts to the after-typing regression below.
			Context.getType("haxe.xml.Access");
			var executed = false;
			Context.onAfterTyping(types -> {
				if (!executed) {
					executed = true;
					execute(types);
				}
			});
		});
	}

	static function execute(finalTypes:Array<ModuleType>):Void {
		assertMacroSha256MatchesStandard();
		assertCompleteProgramCaptureOwnsTargetInput();
		assertFinalProgramFingerprintOwnsOrderedPlainFacts();
		assertFinalProgramFingerprintHandlesResolveFieldSentinels(finalTypes);
		assertCompleteProgramCaptureNormalizesCompilerReachabilityOrder();
		assertTargetReuseProbeFailsClosed();
		assertDirectoryOutputTransactionRollsBack();
		assertLexicalLocalIdentitiesNormalizeHostIds();
		assertLexicalLocalIdentitiesRemainDistinct();
		assertFunctionLiteralOccurrencesHaveStableIdentities();
		assertLexicalLocalIdentityShapeFailsClosed();
		assertLexicalLocalRebindingsReuseIdentityAndMissingLocalsFailClosed();
		assertProgramRevisionNormalizesHostLocalIds();
		assertProgramRevisionKeepsSemanticChanges();
		assertFunctionCacheIsRequestScoped();
		assertLifecycleSchemaFailsClosed();
		assertOutputMetadataRejectsUnsafePaths();
		assertPreserveLossNamesTheOwner();
		assertInvalidationRequiresRebuild();
		assertInvalidationThenRebuildSucceeds();
		assertStructuralLifecycleDoesNotRehashEveryPass();
		assertExactBodyRevisionCannotSurviveReplacement();
		assertExactBodyRevisionDetectsInPlaceMutation();
		assertTraceIsOutputInert();
		ClassFieldHelper.resetDataCaches();
	}

	/** Proves that the macro-optimized implementation keeps the standard digest bytes. **/
	static function assertMacroSha256MatchesStandard():Void {
		final knownVectors = [
			{value: "", expected: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
			{value: "abc", expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
		];
		for (vector in knownVectors)
			if (MacroSha256.encode(vector.value) != vector.expected)
				Context.fatalError("macro SHA-256 did not match a published SHA-256 test vector", Context.currentPos());

		final boundaryValues = [
			"é🙂",
			StringTools.lpad("", "a", 55),
			StringTools.lpad("", "b", 56),
			StringTools.lpad("", "c", 63),
			StringTools.lpad("", "d", 64),
			StringTools.lpad("", "e", 65),
			StringTools.lpad("", "compiler-body", 8192)
		];
		for (value in boundaryValues) {
			final optimized = MacroSha256.encode(value);
			final standard = haxe.crypto.Sha256.encode(value);
			if (optimized != standard)
				Context.fatalError('macro SHA-256 differed from the standard implementation for ${haxe.io.Bytes.ofString(value).length} input bytes ($optimized != $standard)',
					Context.currentPos());
		}
	}

	/**
		Proves that every handled publication checkpoint restores the old tree.

		The filesystem fixture is intentionally target-neutral: it models two
		complete generated directories without assuming anything about the
		language a Reflaxe compiler emits.
	**/
	static function assertDirectoryOutputTransactionRollsBack():Void {
		final tempRoot = Path.join([
			Sys.getEnv("TMPDIR") ?? "/tmp",
			'reflaxe-output-transaction-test-${Std.random(0x3fffffff)}'
		]);
		final publicDirectory = Path.join([tempRoot, "out"]);
		var failure:Dynamic = null;
		try {
			ensureTestDirectory(publicDirectory);
			File.saveContent(Path.join([publicDirectory, "Main.generated"]), "A-main");
			File.saveContent(Path.join([publicDirectory, "OnlyA.generated"]), "A-only");

			final failureStages = [
				DirectoryOutputTransaction.TEST_BEFORE_PUBLIC_MOVE,
				DirectoryOutputTransaction.TEST_AFTER_PUBLIC_MOVE,
				DirectoryOutputTransaction.TEST_AFTER_CANDIDATE_PUBLISH,
				DirectoryOutputTransaction.TEST_BEFORE_CLEANUP
			];
			for (stage in failureStages) {
				final transaction = new DirectoryOutputTransaction(publicDirectory);
				final candidate = transaction.begin();
				File.saveContent(Path.join([candidate, "Main.generated"]), 'B-main-$stage');
				File.saveContent(Path.join([candidate, "OnlyB.generated"]), "B-only");
				transaction.failAtForTest(stage);
				var failed = false;
				try {
					transaction.commit();
				} catch (_) {
					failed = true;
				}
				if (!failed
					|| File.getContent(Path.join([publicDirectory, "Main.generated"])) != "A-main"
					|| File.getContent(Path.join([publicDirectory, "OnlyA.generated"])) != "A-only"
					|| FileSystem.exists(Path.join([publicDirectory, "OnlyB.generated"]))) {
					Context.fatalError('output transaction checkpoint "$stage" did not restore the complete A tree', Context.currentPos());
				}
				assertNoOutputTransactionState(tempRoot);
			}

			final initializationFailure = new DirectoryOutputTransaction(publicDirectory);
			initializationFailure.failAtForTest(DirectoryOutputTransaction.TEST_BEFORE_INITIAL_MARKER);
			var initializationFailed = false;
			try {
				initializationFailure.begin();
			} catch (_) {
				initializationFailed = true;
			}
			if (!initializationFailed
				|| File.getContent(Path.join([publicDirectory, "Main.generated"])) != "A-main"
				|| File.getContent(Path.join([publicDirectory, "OnlyA.generated"])) != "A-only") {
				Context.fatalError("failed output transaction initialization changed the complete A tree", Context.currentPos());
			}
			assertNoOutputTransactionState(tempRoot);

			final aborted = new DirectoryOutputTransaction(publicDirectory);
			final abortedCandidate = aborted.begin();
			File.saveContent(Path.join([abortedCandidate, "Main.generated"]), "aborted");
			aborted.abort();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "A-main")
				Context.fatalError("aborting a private output candidate changed the public tree", Context.currentPos());
			assertNoOutputTransactionState(tempRoot);

			final successful = new DirectoryOutputTransaction(publicDirectory);
			final successfulCandidate = successful.begin();
			File.saveContent(Path.join([successfulCandidate, "Main.generated"]), "B-main");
			File.saveContent(Path.join([successfulCandidate, "OnlyB.generated"]), "B-only");
			successful.commit();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main"
				|| File.getContent(Path.join([publicDirectory, "OnlyB.generated"])) != "B-only"
				|| FileSystem.exists(Path.join([publicDirectory, "OnlyA.generated"]))) {
				Context.fatalError("a successful output transaction did not publish only the complete B tree", Context.currentPos());
			}
			assertNoOutputTransactionState(tempRoot);

			final emptyPublicDirectory = Path.join([tempRoot, "empty-output"]);
			final emptyAbort = new DirectoryOutputTransaction(emptyPublicDirectory);
			final emptyCandidate = emptyAbort.begin();
			File.saveContent(Path.join([emptyCandidate, "Partial.generated"]), "partial");
			emptyAbort.abort();
			if (FileSystem.exists(emptyPublicDirectory)) {
				Context.fatalError("aborting a first-build candidate published an output directory", Context.currentPos());
			}
			assertNoOutputTransactionState(tempRoot);

			final transactionRoot = Path.join([tempRoot, ".out.reflaxe-output-transaction"]);
			final candidateDirectory = Path.join([transactionRoot, "candidate", "out"]);
			final backupDirectory = Path.join([transactionRoot, "backup", "out"]);

			ensureTestDirectory(candidateDirectory);
			File.saveContent(Path.join([candidateDirectory, "Main.generated"]), "interrupted-generation");
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_PREPARING);
			final recoverInterruptedGeneration = new DirectoryOutputTransaction(publicDirectory);
			recoverInterruptedGeneration.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted private generation changed the public tree", Context.currentPos());
			}
			recoverInterruptedGeneration.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(candidateDirectory);
			File.saveContent(Path.join([candidateDirectory, "Main.generated"]), "unpublished-candidate");
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_PUBLIC_MOVE_PENDING);
			final recoverBeforePublicMove = new DirectoryOutputTransaction(publicDirectory);
			recoverBeforePublicMove.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted output recovery changed the public tree before its move", Context.currentPos());
			}
			recoverBeforePublicMove.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(candidateDirectory);
			File.saveContent(Path.join([candidateDirectory, "Main.generated"]), "unpublished-candidate");
			ensureTestDirectory(Path.directory(backupDirectory));
			FileSystem.rename(publicDirectory, backupDirectory);
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_PUBLIC_MOVE_PENDING);
			final recoverPendingPublicMove = new DirectoryOutputTransaction(publicDirectory);
			recoverPendingPublicMove.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted output recovery did not restore a pending public move", Context.currentPos());
			}
			recoverPendingPublicMove.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(candidateDirectory);
			File.saveContent(Path.join([candidateDirectory, "Main.generated"]), "unpublished-candidate");
			ensureTestDirectory(Path.directory(backupDirectory));
			FileSystem.rename(publicDirectory, backupDirectory);
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_PUBLIC_MOVED);
			final restoreMovedPublic = new DirectoryOutputTransaction(publicDirectory);
			restoreMovedPublic.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted output recovery did not restore the moved public tree", Context.currentPos());
			}
			restoreMovedPublic.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(candidateDirectory);
			File.saveContent(Path.join([candidateDirectory, "Main.generated"]), "interrupted-candidate");
			ensureTestDirectory(Path.directory(backupDirectory));
			FileSystem.rename(publicDirectory, backupDirectory);
			FileSystem.rename(candidateDirectory, publicDirectory);
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_PUBLIC_MOVED);
			final rollbackUnmarkedCandidate = new DirectoryOutputTransaction(publicDirectory);
			rollbackUnmarkedCandidate.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted output recovery did not roll back an unmarked candidate publication", Context.currentPos());
			}
			rollbackUnmarkedCandidate.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(backupDirectory);
			File.saveContent(Path.join([backupDirectory, "Main.generated"]), "stale-backup");
			writeTestTransactionMarker(transactionRoot, publicDirectory, DirectoryOutputTransaction.STATE_CANDIDATE_PUBLISHED);
			final finishPublishedCandidate = new DirectoryOutputTransaction(publicDirectory);
			finishPublishedCandidate.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "B-main") {
				Context.fatalError("interrupted output recovery replaced a published candidate with stale backup data", Context.currentPos());
			}
			finishPublishedCandidate.abort();
			assertNoOutputTransactionState(tempRoot);

			final cleanupInterrupted = new DirectoryOutputTransaction(publicDirectory);
			final cleanupCandidate = cleanupInterrupted.begin();
			File.saveContent(Path.join([cleanupCandidate, "Main.generated"]), "C-main");
			cleanupInterrupted.failAtForTest(DirectoryOutputTransaction.TEST_AFTER_BACKUP_CLEANUP);
			cleanupInterrupted.commit();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "C-main") {
				Context.fatalError("cleanup after the publication commit point rolled back the new public tree", Context.currentPos());
			}
			final finishCleanup = new DirectoryOutputTransaction(publicDirectory);
			finishCleanup.begin();
			if (File.getContent(Path.join([publicDirectory, "Main.generated"])) != "C-main") {
				Context.fatalError("recovery after committed cleanup replaced the new public tree", Context.currentPos());
			}
			finishCleanup.abort();
			assertNoOutputTransactionState(tempRoot);

			ensureTestDirectory(transactionRoot);
			File.saveContent(Path.join([transactionRoot, DirectoryOutputTransaction.MARKER_FILENAME]), "{}");
			var malformedFailed = false;
			try {
				new DirectoryOutputTransaction(publicDirectory).begin();
			} catch (_) {
				malformedFailed = true;
			}
			if (!malformedFailed || !FileSystem.exists(transactionRoot)) {
				Context.fatalError("malformed output transaction state was not preserved for explicit recovery", Context.currentPos());
			}
			deleteTestTree(transactionRoot);
		} catch (cause:Dynamic) {
			failure = cause;
		}
		if (FileSystem.exists(tempRoot))
			deleteTestTree(tempRoot);
		if (failure != null)
			throw failure;
	}

	/** Proves persisted file receipts cannot escape their owned output tree. **/
	static function assertOutputMetadataRejectsUnsafePaths():Void {
		for (unsafePath in ["../outside.generated", "..\\outside.generated", "/outside.generated"]) {
			final content = haxe.Json.stringify({
				version: 1,
				id: 1,
				wasCached: false,
				filesGenerated: [unsafePath]
			});
			var failed = false;
			try {
				reflaxe.output.OutputMetadataCodec.decode(content, "unsafe-receipt.json");
			} catch (_) {
				failed = true;
			}
			if (!failed) {
				Context.fatalError('output metadata accepted unsafe generated path "$unsafePath"', Context.currentPos());
			}
		}
	}

	static function writeTestTransactionMarker(transactionRoot:String, publicDirectory:String, state:String):Void {
		ensureTestDirectory(transactionRoot);
		File.saveContent(Path.join([transactionRoot, DirectoryOutputTransaction.MARKER_FILENAME]), [
			DirectoryOutputTransaction.MARKER_FORMAT,
			state,
			Path.normalize(FileSystem.absolutePath(publicDirectory))
		].join("\n"));
	}

	static function assertNoOutputTransactionState(tempRoot:String):Void {
		for (entry in FileSystem.readDirectory(tempRoot)) {
			if (entry.indexOf(".reflaxe-output-transaction") != -1) {
				Context.fatalError('output transaction left private state "$entry"', Context.currentPos());
			}
		}
	}

	static function ensureTestDirectory(path:String):Void {
		if (FileSystem.exists(path))
			return;
		final parent = Path.directory(path);
		if (parent != path && parent.length > 0)
			ensureTestDirectory(parent);
		FileSystem.createDirectory(path);
	}

	static function deleteTestTree(path:String):Void {
		if (!FileSystem.isDirectory(path)) {
			FileSystem.deleteFile(path);
			return;
		}
		for (entry in FileSystem.readDirectory(path))
			deleteTestTree(Path.join([path, entry]));
		FileSystem.deleteDirectory(path);
	}

	static function assertLifecycleSchemaFailsClosed():Void {
		final family = new TestEnvelopeFamily(StructuralEnvelope, []);
		final schemaError = expectLifecycleError(() -> new SemanticLifecycle({
			families: [family],
			pipelineRevision: "semantic-lifecycle-test-v1",
			schemaVersion: 999
		}));
		final pipelineError = expectLifecycleError(() -> new SemanticLifecycle({families: [family], pipelineRevision: ""}));
		if (schemaError.code != "reflaxe:unsupported-semantic-lifecycle-schema"
			|| pipelineError.code != "reflaxe:missing-target-pipeline-revision") {
			Context.fatalError("semantic lifecycle schema or pipeline revision did not fail closed", Context.currentPos());
		}
	}

	static function assertCompleteProgramCaptureOwnsTargetInput():Void {
		final capture = new CompleteProgramTypeCapture();
		final first = moduleType("MyClass");
		final second = moduleType("LazyAddedType");
		final firstType = moduleTypeAsType(first);
		final secondType = moduleTypeAsType(second);
		final completeTypes = [firstType, secondType];

		capture.replace([firstType]);
		capture.replace(completeTypes);
		completeTypes.resize(0);
		final captured = capture.take();
		final expectedCrossModuleOrder = [first, second];
		expectedCrossModuleOrder.sort((left, right) -> Reflect.compare(left.getCommonData().module, right.getCommonData().module));
		if (captured.length != expectedCrossModuleOrder.length) {
			Context.fatalError("the complete onGenerate view did not replace a stale partial request defensively", Context.currentPos());
		}
		for (index in 0...expectedCrossModuleOrder.length) {
			if (captured[index].getUniqueId() != expectedCrossModuleOrder[index].getUniqueId()) {
				Context.fatalError("the complete onGenerate view did not normalize cross-module traversal order", Context.currentPos());
			}
		}
		capture.replace([secondType, firstType]);
		final reversedModules = capture.take();
		for (index in 0...expectedCrossModuleOrder.length) {
			if (reversedModules[index].getUniqueId() != expectedCrossModuleOrder[index].getUniqueId()) {
				Context.fatalError("cross-module normalization changed with the host callback traversal order", Context.currentPos());
			}
		}
		final sourceOrderedTypes = Context.getModule("SameModuleOrder");
		final sourceOrdered = sourceOrderedTypes.map(typeAsModuleType);
		final reversed = sourceOrderedTypes.copy();
		reversed.reverse();
		capture.replace(reversed);
		final normalized = capture.take();
		if (normalized.length != sourceOrdered.length) {
			Context.fatalError("same-module complete-program normalization lost a source declaration", Context.currentPos());
		}
		for (index in 0...sourceOrdered.length) {
			if (normalized[index].getUniqueId() != sourceOrdered[index].getUniqueId()) {
				Context.fatalError("the complete onGenerate view did not preserve same-module source declaration order", Context.currentPos());
			}
		}
		final sameSpanTypes = Context.getModule("SameSpanOrder");
		final sameSpanExpected = sameSpanTypes.map(typeAsModuleType);
		if (sameSpanExpected.length < 2) {
			Context.fatalError("the same-span fixture did not produce its abstract and implementation declarations", Context.currentPos());
		}
		final firstSameSpanPosition = Context.getPosInfos(sameSpanExpected[0].getCommonData().pos);
		for (declaration in sameSpanExpected) {
			final position = Context.getPosInfos(declaration.getCommonData().pos);
			if (position.min != firstSameSpanPosition.min || position.max != firstSameSpanPosition.max) {
				Context.fatalError("the same-span fixture declarations no longer share one source position", Context.currentPos());
			}
		}
		sameSpanExpected.sort((left, right) -> Reflect.compare(left.getUniqueId(), right.getUniqueId()));
		capture.replace(sameSpanTypes);
		final sameSpanOriginal = capture.take();
		for (index in 0...sameSpanExpected.length) {
			if (sameSpanOriginal[index].getUniqueId() != sameSpanExpected[index].getUniqueId()) {
				Context.fatalError("same-span normalization did not use stable declaration identity", Context.currentPos());
			}
		}
		final sameSpanReversed = sameSpanTypes.copy();
		sameSpanReversed.reverse();
		capture.replace(sameSpanReversed);
		final sameSpanNormalized = capture.take();
		for (index in 0...sameSpanExpected.length) {
			if (sameSpanNormalized[index].getUniqueId() != sameSpanExpected[index].getUniqueId()) {
				Context.fatalError("same-span normalization depended on the host callback traversal order", Context.currentPos());
			}
		}
		final missing = expectLifecycleError(() -> capture.take());
		if (missing.code != "reflaxe:missing-complete-program") {
			Context.fatalError("a consumed complete-program capture did not fail closed", Context.currentPos());
		}
		final duplicate = expectLifecycleError(() -> capture.replace([firstType, firstType]));
		if (duplicate.code != "reflaxe:duplicate-complete-program-type") {
			Context.fatalError("a duplicate complete-program declaration did not fail closed", Context.currentPos());
		}
		final functionType = Context.typeof(macro function(value:Int):Int return value);
		final malformed = expectLifecycleError(() -> capture.replace([functionType]));
		if (malformed.code != "reflaxe:malformed-complete-program-type") {
			Context.fatalError("a non-declaration complete-program value did not fail closed", Context.currentPos());
		}
		final forwardRevision = ProgramRevision.fromModuleTypes([first, second]);
		final reverseRevision = ProgramRevision.fromModuleTypes([second, first]);
		if (forwardRevision.id != reverseRevision.id) {
			Context.fatalError('program revision depended on module callback order: ${forwardRevision.id} != ${reverseRevision.id}', Context.currentPos());
		}
		if (ProgramRevision.fromModuleTypes([first]).id == forwardRevision.id) {
			Context.fatalError("program revision ignored a retained module", Context.currentPos());
		}
	}

	/**
		Proves the richer snapshot preserves order while retaining compatibility.
	**/
	static function assertFinalProgramFingerprintOwnsOrderedPlainFacts():Void {
		final first = moduleType("MyClass");
		final second = moduleType("LazyAddedType");
		final subject = moduleType("ProgramRevisionSubject");
		NormalizedProgramBodyDigest.resetDigestCallCount();
		FinalProgramFingerprintSnapshot.fromModuleTypes([subject]);
		final expectedSubjectCalls = Context.getMainExpr() == null ? 1 : 2;
		if (NormalizedProgramBodyDigest.getDigestCallCount() != expectedSubjectCalls) {
			Context.fatalError("the final-program snapshot repeated a typed-body fingerprint walk", Context.currentPos());
		}

		NormalizedProgramBodyDigest.resetDigestCallCount();
		final forward = FinalProgramFingerprintSnapshot.fromModuleTypes([first, second]);
		final digestCalls = NormalizedProgramBodyDigest.getDigestCallCount();
		final reverse = FinalProgramFingerprintSnapshot.fromModuleTypes([second, first]);
		if (forward.programRevision.id != reverse.programRevision.id
			|| forward.programMembershipRevision == reverse.programMembershipRevision
			|| forward.id == reverse.id) {
			Context.fatalError("the final-program snapshot lost order or changed the compatibility program revision", Context.currentPos());
		}
		if (digestCalls <= 0) {
			Context.fatalError("the final-program snapshot did not observe any typed bodies", Context.currentPos());
		}
		final declarations = forward.declarations();
		final originalCount = declarations.length;
		declarations.resize(0);
		final blockers = forward.sourceAuthorityBlockers();
		final originalBlockerCount = blockers.length;
		blockers.push("test-only-mutation");
		if (forward.declarations().length != originalCount || forward.sourceAuthorityBlockers().length != originalBlockerCount) {
			Context.fatalError("the final-program snapshot exposed mutable declaration or authority arrays", Context.currentPos());
		}
		if (forward.programRevision.id != ProgramRevision.fromModuleTypes([first, second]).id) {
			Context.fatalError("the final-program snapshot diverged from the compatibility program revision", Context.currentPos());
		}

		final firstEncoding = new CanonicalFingerprint("collision-test");
		firstEncoding.add("left", "a|b");
		firstEncoding.add("right", "c");
		final secondEncoding = new CanonicalFingerprint("collision-test");
		secondEncoding.add("left", "a");
		secondEncoding.add("right", "b|c");
		if (firstEncoding.digest() == secondEncoding.digest()) {
			Context.fatalError("canonical fingerprint encoding admitted a delimiter collision", Context.currentPos());
		}
	}

	/**
		Proves Haxe's placeholder resolve fields remain exact fingerprint input.

		Haxe 4.3.7 exposes the dot-access hooks in `haxe.xml.Access` as non-null
		`ClassField` objects whose own name, type, and kind are null. Before this
		regression, fingerprinting asked Haxe to render the null type and stopped
		compilation before any target could run.

		The placeholder's presence is now a stable fact distinct from no resolve
		hook. A partial field must block reuse, and the placeholder is not valid
		in operator or cast slots. This test exercises those distinctions rather
		than merely repeating the implementation's null check.
	**/
	static function assertFinalProgramFingerprintHandlesResolveFieldSentinels(finalTypes:Array<ModuleType>):Void {
		final resolveAbstracts = finalTypes.filter(moduleType -> switch (moduleType) {
			case TAbstract(reference): final abstractType = reference.get(); StringTools.startsWith(abstractType.module,
					"haxe.xml.Access") && (abstractType.resolve != null || abstractType.resolveWrite != null);
			case _:
				false;
		});
		var sentinelCount = 0;
		for (moduleType in resolveAbstracts) {
			switch (moduleType) {
				case TAbstract(reference):
					final abstractType = reference.get();
					for (field in [abstractType.resolve, abstractType.resolveWrite]) {
						if (isAllNullHostField(field))
							sentinelCount += 1;
					}
				case _:
			}
		}
		if (resolveAbstracts.length == 0 || (Context.definedValue("haxe") == "4.3.7" && sentinelCount != 6)) {
			Context.fatalError('the resolve-field regression did not observe the expected Haxe host shape'
				+ ' (abstracts=${resolveAbstracts.length}, sentinels=$sentinelCount)',
				Context.currentPos());
		}

		final first = FinalProgramFingerprintSnapshot.fromModuleTypes(resolveAbstracts);
		final second = FinalProgramFingerprintSnapshot.fromModuleTypes(resolveAbstracts);
		if (!first.sourceAuthorityComplete || first.id != second.id || first.declarations().length != resolveAbstracts.length) {
			Context.fatalError("resolve-field sentinels did not produce one complete deterministic final-program fingerprint", Context.currentPos());
		}

		var completeField:Null<ClassField> = null;
		for (moduleType in finalTypes) {
			if (completeField != null)
				break;
			switch (moduleType) {
				case TClassDecl(reference):
					final fields = reference.get().fields.get();
					if (fields.length > 0)
						completeField = fields[0];
				case _:
			}
		}
		if (completeField == null)
			Context.fatalError("the resolve-field regression could not find a complete field for its differential check", Context.currentPos());

		final exactSentinel = nullClassField();
		final malformedPartial = nullClassField();
		Reflect.setField(malformedPartial, "doc", "unexpected partial host field");
		final absent = fingerprintWithResolveField(resolveAbstracts[0], null);
		final sentinel = fingerprintWithResolveField(resolveAbstracts[0], exactSentinel);
		final complete = fingerprintWithResolveField(resolveAbstracts[0], completeField);
		final partial = fingerprintWithResolveField(resolveAbstracts[0], malformedPartial);
		final wrongSlot = fingerprintWithOperatorField(resolveAbstracts[0], nullClassField());
		if (!absent.sourceAuthorityComplete || !sentinel.sourceAuthorityComplete || !complete.sourceAuthorityComplete) {
			Context.fatalError("absent, exact sentinel, or complete resolve fields unexpectedly blocked source authority", Context.currentPos());
		}
		for (snapshot in [partial, wrongSlot]) {
			if (snapshot.sourceAuthorityComplete || snapshot.sourceAuthorityBlockers().indexOf("field-reference-incomplete") < 0) {
				Context.fatalError("a partial or out-of-slot host field did not block target reuse", Context.currentPos());
			}
			final probe = TargetReuseProbe.build(snapshot, "test-target", [], []);
			if (probe.eligible
				|| probe.blockers().indexOf("reflaxe:incomplete-source-authority") < 0
				|| probe.blockers().indexOf("reflaxe:source-authority:field-reference-incomplete") < 0) {
				Context.fatalError("a source-authority failure did not retain its specific target-reuse blocker", Context.currentPos());
			}
		}
		final identities = [absent.id, sentinel.id, complete.id, partial.id, wrongSlot.id];
		for (left in 0...identities.length) {
			for (right in left + 1...identities.length) {
				if (identities[left] == identities[right])
					Context.fatalError("distinct resolve-field states produced the same final-program fingerprint", Context.currentPos());
			}
		}
	}

	/** Returns true only for the complete all-null shape exposed by Haxe 4.3.7. **/
	static function isAllNullHostField(field:Null<ClassField>):Bool {
		if (field == null)
			return false;
		final name:Null<String> = cast field.name;
		final type:Null<haxe.macro.Type> = cast field.type;
		final kind:Null<haxe.macro.Type.FieldKind> = cast field.kind;
		final isPublic:Null<Bool> = cast field.isPublic;
		final isExtern:Null<Bool> = cast field.isExtern;
		final isFinal:Null<Bool> = cast field.isFinal;
		final isAbstract:Null<Bool> = cast field.isAbstract;
		final parameters:Null<Array<haxe.macro.Type.TypeParameter>> = cast field.params;
		final metadata:Null<MetaAccess> = cast field.meta;
		final position:Null<haxe.macro.Expr.Position> = cast field.pos;
		final documentation:Null<String> = cast field.doc;
		final overloads:Null<haxe.macro.Type.Ref<Array<ClassField>>> = cast field.overloads;
		final expressionProvider:Null<Void->Null<TypedExpr>> = cast field.expr;
		return name == null && type == null && kind == null && isPublic == null && isExtern == null && isFinal == null && isAbstract == null
			&& parameters == null && metadata == null && position == null && documentation == null && overloads == null && expressionProvider == null;
	}

	/** Creates the host-shaped empty field used by the differential regression. **/
	static function nullClassField():ClassField {
		return cast {
			name: null,
			type: null,
			isPublic: null,
			isExtern: null,
			isFinal: null,
			isAbstract: null,
			params: null,
			meta: null,
			kind: null,
			expr: null,
			pos: null,
			doc: null,
			overloads: null
		};
	}

	/** Fingerprints one copied abstract with only the supplied resolve hook. **/
	static function fingerprintWithResolveField(owner:ModuleType, field:Null<ClassField>):FinalProgramFingerprintSnapshot {
		return FinalProgramFingerprintSnapshot.fromModuleTypes([
			copyAbstract(owner, abstractType -> {
				abstractType.resolve = field;
				abstractType.resolveWrite = null;
			})
		]);
	}

	/** Fingerprints an all-null field outside the resolve-only exception. **/
	static function fingerprintWithOperatorField(owner:ModuleType, field:ClassField):FinalProgramFingerprintSnapshot {
		return FinalProgramFingerprintSnapshot.fromModuleTypes([
			copyAbstract(owner, abstractType -> {
				abstractType.resolve = null;
				abstractType.resolveWrite = null;
				abstractType.binops = [{op: OpAdd, field: field}];
			})
		]);
	}

	/**
		Copies one abstract declaration without mutating Haxe's compiler-owned type.

		The copied reference is used only during this assertion. Production
		fingerprints continue to consume the host's original final program.
	**/
	static function copyAbstract(owner:ModuleType, mutate:haxe.macro.Type.AbstractType->Void):ModuleType {
		return switch (owner) {
			case TAbstract(reference):
				final abstractType:haxe.macro.Type.AbstractType = cast Reflect.copy(reference.get());
				mutate(abstractType);
				final copiedReference:haxe.macro.Type.Ref<haxe.macro.Type.AbstractType> = {
					get: () -> abstractType,
					toString: () -> reference.toString()
				};
				TAbstract(copiedReference);
			case _:
				throw "resolve-field regression expected an abstract declaration";
		};
	}

	/**
		Proves cold and warm requests expose the same metadata to a target.

		Haxe's server can reverse its empty `@:used` and `@:directlyUsed`
		reachability flags on a cached declaration. The complete-program capture
		must reorder the actual metadata before either the target or fingerprint
		reads it. This fixture also proves source annotations, parameterized
		entries, near-match positions, and unknown files keep their original
		slots because they are not proven compiler bookkeeping.
	**/
	static function assertCompleteProgramCaptureNormalizesCompilerReachabilityOrder():Void {
		final declaration = moduleType("CompilerReachabilityMetadata");
		var common = declaration.getCommonData();
		final original = common.meta.get();
		final originalRevision = metadataRevisionForTest(original);
		final sourceMarkers = original.filter(entry -> entry.name == ":used" || entry.name == ":directlyUsed");
		if (sourceMarkers.length != 2)
			Context.fatalError("the reachability fixture did not retain both source-written metadata entries", Context.currentPos());
		final declarationPosition = Context.getPosInfos(common.pos);
		final compilerUsedPosition = Context.makePosition({
			file: declarationPosition.file,
			min: declarationPosition.min,
			max: declarationPosition.min
		});
		final capture = new CompleteProgramTypeCapture();
		var failure:Dynamic = null;
		try {
			addUncertainReachabilityMetadata(common.meta, common.pos);
			common.meta.add(":used", [], compilerUsedPosition);
			common.meta.add(":used", [], compilerUsedPosition);
			common.meta.add(":directlyUsed", [], common.pos);
			final coldBefore = common.meta.get();
			capture.replace([moduleTypeAsType(declaration)]);
			capture.take();
			// A target reads a fresh declaration view after capture. Reusing the
			// earlier MetaAccess wrapper here would inspect its old metadata
			// snapshot instead of the normalized declaration that targets receive.
			common = declaration.getCommonData();
			final coldVisible = common.meta.get();
			assertUnmatchedMetadataSlotsUnchanged(coldBefore, coldVisible, common.pos);
			assertCompilerMarkerOrder("cold", coldVisible, common.pos);
			final coldFingerprint = FinalProgramFingerprintSnapshot.fromModuleTypes([declaration]).id;

			replaceTestMetadata(common.meta, original);
			addUncertainReachabilityMetadata(common.meta, common.pos);
			common.meta.add(":used", [], compilerUsedPosition);
			common.meta.add(":directlyUsed", [], common.pos);
			common.meta.add(":used", [], compilerUsedPosition);
			final warmBefore = common.meta.get();
			capture.replace([moduleTypeAsType(declaration)]);
			capture.take();
			common = declaration.getCommonData();
			final warmVisible = common.meta.get();
			assertUnmatchedMetadataSlotsUnchanged(warmBefore, warmVisible, common.pos);
			assertCompilerMarkerOrder("warm", warmVisible, common.pos);
			final warmFingerprint = FinalProgramFingerprintSnapshot.fromModuleTypes([declaration]).id;
			if (metadataRevisionForTest(warmVisible) != metadataRevisionForTest(coldVisible) || warmFingerprint != coldFingerprint) {
				Context.fatalError("cold and warm reachability order did not normalize to one target-visible program", Context.currentPos());
			}

			capture.replace([moduleTypeAsType(declaration)]);
			capture.take();
			common = declaration.getCommonData();
			if (metadataRevisionForTest(common.meta.get()) != metadataRevisionForTest(warmVisible)) {
				Context.fatalError("reachability metadata normalization was not idempotent", Context.currentPos());
			}
		} catch (cause:Dynamic) {
			failure = cause;
		}

		common = declaration.getCommonData();
		replaceTestMetadata(common.meta, original);
		if (metadataRevisionForTest(common.meta.get()) != originalRevision) {
			Context.fatalError("the reachability-order fixture did not restore its source metadata", Context.currentPos());
		}
		if (failure != null)
			throw failure;
	}

	/**
		Adds entries that resemble Haxe flags but remain target-authored input.

		Each entry differs from Haxe's compiler shape in one important way: it
		has an argument, ends before the declaration, or uses an unknown file.
		They make the test reject an overly broad normalization rule.
	**/
	static function addUncertainReachabilityMetadata(access:MetaAccess, ownerPosition:haxe.macro.Expr.Position):Void {
		final owner = Context.getPosInfos(ownerPosition);
		access.add(":used", [macro "parameterized"], ownerPosition);
		access.add(":directlyUsed", [], Context.makePosition({
			file: owner.file,
			min: owner.min,
			max: owner.max > owner.min ? owner.max - 1 : owner.max + 1
		}));
		access.add(":used", [], Context.makePosition({
			file: "?",
			min: owner.min,
			max: owner.min
		}));
	}

	/** Proves every entry outside the matched compiler slots stayed in place. **/
	static function assertUnmatchedMetadataSlotsUnchanged(before:Array<MetadataEntry>, after:Array<MetadataEntry>,
			ownerPosition:haxe.macro.Expr.Position):Void {
		if (before.length != after.length)
			Context.fatalError("reachability metadata normalization added or removed an entry", Context.currentPos());
		for (index in 0...before.length) {
			if (!isCompilerMarkerForTest(before[index], ownerPosition)
				&& metadataEntryRevisionForTest(before[index]) != metadataEntryRevisionForTest(after[index])) {
				Context.fatalError("reachability metadata normalization moved target-authored metadata", Context.currentPos());
			}
		}
	}

	/**
		Proves one direct flag precedes both retained used-flag duplicates.

		The phase name identifies whether a failure came from the fresh or
		reused compiler view; it does not change the ordering rule.
	**/
	static function assertCompilerMarkerOrder(phase:String, metadata:Array<MetadataEntry>, ownerPosition:haxe.macro.Expr.Position):Void {
		final names = metadata.filter(entry -> isCompilerMarkerForTest(entry, ownerPosition)).map(entry -> entry.name);
		if (names.join("|") != ":directlyUsed|:used|:used") {
			Context.fatalError('$phase compiler reachability flags were not retained in their deterministic order: ${names.join("|")}', Context.currentPos());
		}
	}

	static function isCompilerMarkerForTest(entry:MetadataEntry, ownerPosition:haxe.macro.Expr.Position):Bool {
		if ((entry.name != ":used" && entry.name != ":directlyUsed") || (entry.params ?? []).length != 0)
			return false;
		final marker = Context.getPosInfos(entry.pos);
		final owner = Context.getPosInfos(ownerPosition);
		if (StringTools.replace(marker.file ?? "", "\\", "/") != StringTools.replace(owner.file ?? "", "\\", "/"))
			return false;
		return switch (entry.name) {
			case ":used": marker.min == marker.max && marker.min == owner.min;
			case ":directlyUsed": marker.min == owner.min && marker.max == owner.max;
			case _: false;
		}
	}

	/** Recreates the exact metadata order saved at the start of the fixture. **/
	static function replaceTestMetadata(access:MetaAccess, metadata:Array<MetadataEntry>):Void {
		final currentNames:Map<String, Bool> = [];
		for (entry in access.get()) {
			if (!currentNames.exists(entry.name)) {
				currentNames.set(entry.name, true);
				access.remove(entry.name);
			}
		}
		var index = metadata.length;
		while (index > 0) {
			index -= 1;
			final entry = metadata[index];
			access.add(entry.name, entry.params ?? [], entry.pos);
		}
	}

	static function metadataRevisionForTest(metadata:Array<MetadataEntry>):String {
		return haxe.Json.stringify(metadata.map(metadataEntryRevisionForTest));
	}

	static function metadataEntryRevisionForTest(entry:MetadataEntry):String {
		final position = Context.getPosInfos(entry.pos);
		return haxe.Json.stringify({
			name: entry.name,
			parameters: (entry.params ?? []).map(ExprTools.toString),
			file: StringTools.replace(position.file ?? "", "\\", "/"),
			minimum: position.min,
			maximum: position.max
		});
	}

	/** Proves exact target keys are order-stable and eligibility fails closed. **/
	static function assertTargetReuseProbeFailsClosed():Void {
		final frameworkRevision = ReflaxeImplementationRevision.current();
		if (!~/^sha256:[0-9a-f]{64}$/.match(frameworkRevision)) {
			Context.fatalError("the generic Reflaxe source inventory did not produce an exact SHA-256 revision", Context.currentPos());
		}
		final snapshot = FinalProgramFingerprintSnapshot.fromModuleTypes([moduleType("ProgramRevisionSubject")]);
		final forward = TargetReuseProbe.build(snapshot, "test-target", [
			new TargetReuseRevisionComponent("implementation", "sha256:implementation"),
			new TargetReuseRevisionComponent("configuration", "sha256:configuration")
		], []);
		final reverse = TargetReuseProbe.build(snapshot, "test-target", [
			new TargetReuseRevisionComponent("configuration", "sha256:configuration"),
			new TargetReuseRevisionComponent("implementation", "sha256:implementation")
		], []);
		if (forward.requestRevision != reverse.requestRevision || forward.eligible != snapshot.sourceAuthorityComplete) {
			Context.fatalError("target reuse key order or source-authority eligibility was unstable", Context.currentPos());
		}
		final blocked = TargetReuseProbe.build(snapshot, "test-target", [], ["z-reason", "a-reason", "z-reason"]);
		if (blocked.eligible || blocked.blockers().join("|") != "a-reason|z-reason") {
			Context.fatalError("target reuse blockers were not sorted, deduplicated, and fail-closed", Context.currentPos());
		}
		final unconfigured = TargetReuseProbe.build(snapshot, null, [], []);
		if (unconfigured.eligible
			|| unconfigured.requestRevision != null
			|| unconfigured.blockers().indexOf("reflaxe:target-reuse-not-configured") == -1) {
			Context.fatalError("an unconfigured target received a reusable request key", Context.currentPos());
		}
		final duplicateError = expectMessage(() -> TargetReuseProbe.build(snapshot, "test-target", [
			new TargetReuseRevisionComponent("implementation", "sha256:first"),
			new TargetReuseRevisionComponent("implementation", "sha256:second")
		], []));
		if (duplicateError.indexOf("supplied more than once") == -1) {
			Context.fatalError("duplicate target reuse revision domains did not fail closed", Context.currentPos());
		}
	}

	static function assertProgramRevisionNormalizesHostLocalIds():Void {
		final first = Context.typeExpr(macro {
			var total = 0;
			var add = function(value:Int) total += value;
			for (item in [1, 2])
				add(item);
			try {
				throw "revision probe";
			} catch (error:String) {
				total += error.length;
			}
			total;
		});
		Context.typeExpr(macro {
			var unrelated = 0;
			unrelated;
		});
		final second = Context.typeExpr(macro {
			var total = 0;
			var add = function(value:Int) total += value;
			for (item in [1, 2])
				add(item);
			try {
				throw "revision probe";
			} catch (error:String) {
				total += error.length;
			}
			total;
		});
		final firstRaw = TypedExprTools.toString(first);
		final secondRaw = TypedExprTools.toString(second);
		if (firstRaw == secondRaw) {
			Context.fatalError("local-number regression setup did not perturb Haxe's detailed typed-expression rendering", Context.currentPos());
		}
		if (NormalizedProgramBodyDigest.digestExpression(first) != NormalizedProgramBodyDigest.digestExpression(second)) {
			Context.fatalError("program body digest retained process-wide local-variable numbering", Context.currentPos());
		}
		if (FunctionBodyRevision.digestExpression(first) != FunctionBodyRevision.digestExpression(second)) {
			Context.fatalError("function body revision retained process-wide local-variable numbering", Context.currentPos());
		}
	}

	static function assertLexicalLocalIdentitiesNormalizeHostIds():Void {
		final first = Context.typeExpr(macro {
			var total = 0;
			total += 1;
			total;
		});
		Context.typeExpr(macro {
			var unrelatedFirst = 0;
			var unrelatedSecond = unrelatedFirst + 1;
			unrelatedSecond;
		});
		final second = Context.typeExpr(macro {
			var total = 0;
			total += 1;
			total;
		});
		final firstPlan = LexicalLocalIdentityPlan.build("identity-test-owner", first);
		final secondPlan = LexicalLocalIdentityPlan.build("identity-test-owner", second);
		final firstIds = firstPlan.identities().map(identity -> identity.id);
		final secondIds = secondPlan.identities().map(identity -> identity.id);
		if (TypedExprTools.toString(first) == TypedExprTools.toString(second)) {
			Context.fatalError("lexical-local regression setup did not perturb Haxe IDs", Context.currentPos());
		}
		if (firstIds.join("|") != secondIds.join("|")) {
			Context.fatalError("lexical-local identities retained Haxe allocation order", Context.currentPos());
		}
	}

	static function assertLexicalLocalIdentitiesRemainDistinct():Void {
		final expression = Context.typeExpr(macro {
			var value = 0;
			final nested = function(value:Int):Int {
				for (value in [value]) {
					try {
						if (value > 0)
							throw "positive";
					} catch (value:String) {
						return value.length;
					}
				}
				return value;
			};
			nested(value);
		});
		final identities = LexicalLocalIdentityPlan.build("identity-distinction-owner", expression).identities();
		final unique:Map<String, Bool> = [];
		for (identity in identities) {
			if (unique.exists(identity.id)) {
				Context.fatalError('duplicate lexical-local identity ${identity.id}', Context.currentPos());
			}
			unique.set(identity.id, true);
		}
		final valueIdentities = identities.filter(identity -> identity.name == "value");
		final kinds = valueIdentities.map(identity -> identity.kind);
		kinds.sort(Reflect.compare);
		if (valueIdentities.length != 4 || kinds.join("|") != "catch-binding|function-argument|variable|variable") {
			Context.fatalError('shadowed lambda, loop, catch, and variable bindings were not distinct: ${kinds.join("|")}', Context.currentPos());
		}
	}

	/**
		Proves the existing lexical traversal can name function literals directly.

		A function-literal occurrence is one structural position inside the enclosing
		typed body. The identity must work even when the literal has no arguments,
		because there is then no parameter identity from which a target could safely
		infer the function position.
	**/
	static function assertFunctionLiteralOccurrencesHaveStableIdentities():Void {
		final first = Context.typeExpr(macro {
			final firstZero = function():Int return 1;
			final withArgument = function(value:Int):Int {
				final deep = function():Int return 1;
				return value + deep();
			};
			final secondZero = function():Int return 3;
			firstZero() + withArgument(2) + secondZero();
		});
		Context.typeExpr(macro {
			final unrelated = function(value:String):String return value;
			unrelated("shift host allocations");
		});
		final second = Context.typeExpr(macro {
			final firstZero = function():Int return 1;
			final withArgument = function(value:Int):Int {
				final deep = function():Int return 1;
				return value + deep();
			};
			final secondZero = function():Int return 3;
			firstZero() + withArgument(2) + secondZero();
		});
		final firstFunctions = collectFunctionLiterals(first);
		final secondFunctions = collectFunctionLiterals(second);
		final firstPlan = LexicalLocalIdentityPlan.build("function-occurrence-owner", first);
		final secondPlan = LexicalLocalIdentityPlan.build("function-occurrence-owner", second);
		final differentOwnerPlan = LexicalLocalIdentityPlan.build("different-function-occurrence-owner", first);
		final firstIds = firstFunctions.map(expression -> firstPlan.requireFunctionOccurrence(expression).id);
		final secondIds = secondFunctions.map(expression -> secondPlan.requireFunctionOccurrence(expression).id);
		final firstParents = firstFunctions.map(expression -> firstPlan.requireFunctionOccurrence(expression).parentOccurrenceId);
		final unique:Map<String, Bool> = [];
		for (id in firstIds)
			unique.set(id, true);
		final foreignError = expectMessage(() -> secondPlan.requireFunctionOccurrence(firstFunctions[0]));
		if (firstFunctions.length != 4
			|| secondFunctions.length != 4
			|| firstPlan.functionOccurrences().length != 4
			|| firstIds.join("|") != secondIds.join("|")
			|| Lambda.count(unique) != 4
			|| firstParents[0] != null
			|| firstParents[1] != null
			|| firstParents[2] != firstIds[1]
			|| firstParents[3] != null
			|| firstIds[0] == differentOwnerPlan.requireFunctionOccurrence(firstFunctions[0]).id
			|| foreignError.indexOf("reflaxe:missing-function-occurrence-identity") == -1) {
			Context.fatalError('function-literal occurrence identities were not stable, distinct, owner-scoped, and request-local: first=${firstIds.join("|")} second=${secondIds.join("|")} foreign=$foreignError',
				Context.currentPos());
		}
	}

	/** Returns function expressions in the explicit typed-tree traversal order. **/
	static function collectFunctionLiterals(root:TypedExpr):Array<TypedExpr> {
		final result:Array<TypedExpr> = [];
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TFunction(_):
					result.push(expression);
				case _:
			}
			TypedExprTools.iter(expression, visit);
		}
		visit(root);
		return result;
	}

	static function assertLexicalLocalIdentityShapeFailsClosed():Void {
		final valid = LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "0", 64);
		final validFunctionOccurrence = LexicalLocalIdentityPlan.FUNCTION_OCCURRENCE_ID_PREFIX + StringTools.lpad("", "0", 64);
		if (!LexicalLocalIdentityPlan.isReusableId(valid)
			|| LexicalLocalIdentityPlan.isReusableId("17")
			|| LexicalLocalIdentityPlan.isReusableId(LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "0", 63))
			|| LexicalLocalIdentityPlan.isReusableId(LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "G", 64))
			|| !LexicalLocalIdentityPlan.isReusableFunctionOccurrenceId(validFunctionOccurrence)
			|| LexicalLocalIdentityPlan.isReusableFunctionOccurrenceId("17")
			|| LexicalLocalIdentityPlan.isReusableFunctionOccurrenceId(LexicalLocalIdentityPlan.FUNCTION_OCCURRENCE_ID_PREFIX + StringTools.lpad("", "0", 63))
			|| LexicalLocalIdentityPlan.isReusableFunctionOccurrenceId(LexicalLocalIdentityPlan.FUNCTION_OCCURRENCE_ID_PREFIX + StringTools.lpad("", "G",
				64))) {
			Context.fatalError("lexical-local publication validation accepted a host ID or rejected one complete stable ID", Context.currentPos());
		}
	}

	/**
		Proves assignment-to-declaration preprocessing can rebind one Haxe local
		without inventing a second stable identity.
	**/
	static function assertLexicalLocalRebindingsReuseIdentityAndMissingLocalsFailClosed():Void {
		final declared = Context.typeExpr(macro {
			var value = 1;
			value;
		});
		final block = switch (declared.expr) {
			case TBlock(expressions): expressions;
			case _: Context.fatalError("expected a typed block for lexical-local failure fixtures", Context.currentPos());
		}
		final local = switch (block[0].expr) {
			case TVar(local, _): local;
			case _: Context.fatalError("expected a typed local declaration", Context.currentPos());
		}
		final rebound:TypedExpr = {
			expr: haxe.macro.Type.TypedExprDef.TBlock([block[0], block[0], block[1]]),
			pos: declared.pos,
			t: declared.t
		};
		final missing:TypedExpr = {
			expr: haxe.macro.Type.TypedExprDef.TBlock([block[1]]),
			pos: declared.pos,
			t: declared.t
		};
		final reboundPlan = LexicalLocalIdentityPlan.build("rebound-owner", rebound);
		final missingError = expectMessage(() -> LexicalLocalIdentityPlan.build("missing-owner", missing));
		if (reboundPlan.identities().length != 1 || missingError.indexOf("reflaxe:missing-lexical-local-identity") == -1) {
			Context.fatalError('lexical-local rebinding or missing-local validation failed: identities=${reboundPlan.identities().length} missing=$missingError',
				Context.currentPos());
		}
	}

	static function assertProgramRevisionKeepsSemanticChanges():Void {
		final baseline = Context.typeExpr(macro {
			var value = 1;
			value + 1;
		});
		final changedValue = Context.typeExpr(macro {
			var value = 1;
			value + 2;
		});
		final changedType = Context.typeExpr(macro {
			var value:Float = 1;
			value + 1;
		});
		final firstAccess = Context.typeExpr(macro Sys.print("revision probe"));
		final secondAccess = Context.typeExpr(macro Sys.println("revision probe"));
		final firstLiteral = Context.typeExpr(macro "[Local fake(10):Int]");
		final secondLiteral = Context.typeExpr(macro "[Local fake(20):Int]");
		final baselineDigest = NormalizedProgramBodyDigest.digestExpression(baseline);
		if (baselineDigest == NormalizedProgramBodyDigest.digestExpression(changedValue)
			|| baselineDigest == NormalizedProgramBodyDigest.digestExpression(changedType)
			|| NormalizedProgramBodyDigest.digestExpression(firstAccess) == NormalizedProgramBodyDigest.digestExpression(secondAccess)
			|| NormalizedProgramBodyDigest.digestExpression(firstLiteral) == NormalizedProgramBodyDigest.digestExpression(secondLiteral)) {
			Context.fatalError("program body digest erased a behavior, type, or resolved-field change", Context.currentPos());
		}
	}

	static function assertFunctionCacheIsRequestScoped():Void {
		final resolved = testMethod();
		ClassFieldHelper.resetDataCaches();
		final first = resolved.field.findFuncData(resolved.cls, true);
		if (first == null) {
			Context.fatalError("test method data was not available", Context.currentPos());
		}
		first.setExpr(Context.typeExpr(macro Sys.println("mutated cached body")));
		ClassFieldHelper.resetDataCaches();
		final second = resolved.field.findFuncData(resolved.cls, true);
		if (second == null
			|| first == second
			|| first.id != second.id
			|| second.bodyRevision.generation != 0
			|| second.id.indexOf("|static|function|") == -1) {
			Context.fatalError("mutable ClassFuncData escaped its compilation request", Context.currentPos());
		}
	}

	static function assertPreserveLossNamesTheOwner():Void {
		final family = new TestEnvelopeFamily(StructuralEnvelope, [DropEnvelope.ID => Preserve]);
		final data = markedData();
		final error = expectLifecycleError(() -> lifecycle(family).process(data, compiler(), [Custom(new DropEnvelope())]));
		if (error.code != "reflaxe:semantic-contract-violation"
			|| error.message.indexOf(DropEnvelope.ID) == -1
			|| error.message.indexOf(TestEnvelopeFamily.ID) == -1) {
			Context.fatalError('preserve failure did not name its pass and family: ${error.message}', Context.currentPos());
		}
	}

	static function assertInvalidationRequiresRebuild():Void {
		final family = new TestEnvelopeFamily(StructuralEnvelope, [DropEnvelope.ID => Invalidate]);
		final error = expectLifecycleError(() -> lifecycle(family).process(markedData(), compiler(), [Custom(new DropEnvelope())]));
		if (error.code != "reflaxe:semantic-family-invalidated" || error.message.indexOf(DropEnvelope.ID) == -1) {
			Context.fatalError('invalidated family reached emission without the expected diagnostic: ${error.message}', Context.currentPos());
		}
	}

	static function assertInvalidationThenRebuildSucceeds():Void {
		final family = new TestEnvelopeFamily(StructuralEnvelope, [DropEnvelope.ID => Invalidate, RebuildEnvelope.ID => Replace]);
		lifecycle(family).process(markedData(), compiler(), [Custom(new DropEnvelope()), Custom(new RebuildEnvelope())]);
	}

	static function assertExactBodyRevisionCannotSurviveReplacement():Void {
		final family = new TestEnvelopeFamily(ExactBodyRevision, [WrapRoot.ID => Preserve]);
		final data = markedData();
		final before = data.bodyRevision.id;
		final error = expectLifecycleError(() -> lifecycle(family).process(data, compiler(), [Custom(new WrapRoot())]));
		if (data.bodyRevision.id == before || error.code != "reflaxe:semantic-contract-violation") {
			Context.fatalError("root replacement did not invalidate an exact-body analysis", Context.currentPos());
		}
	}

	static function assertStructuralLifecycleDoesNotRehashEveryPass():Void {
		final data = markedData();
		final initialGeneration = data.bodyRevision.generation;
		final family = new TestEnvelopeFamily(StructuralEnvelope, [NoOp.ID => Preserve, MutateBodyInPlace.ID => Preserve]);
		FunctionBodyRevision.resetDigestCallCount();
		lifecycle(family).process(data, compiler(), [Custom(new NoOp()), Custom(new MutateBodyInPlace()), Custom(new NoOp())]);
		if (FunctionBodyRevision.getDigestCallCount() != 2) {
			Context.fatalError("a structural lifecycle did more than its entry and exit body-revision checks", Context.currentPos());
		}
		if (data.bodyRevision.generation <= initialGeneration) {
			Context.fatalError("the exit check did not record an in-place body change", Context.currentPos());
		}
		final firstId = data.bodyRevision.id;
		final secondId = data.bodyRevision.id;
		if (firstId != secondId || FunctionBodyRevision.getDigestCallCount() != 2) {
			Context.fatalError("a lazily requested body revision was not stable and cached", Context.currentPos());
		}
	}

	static function assertExactBodyRevisionDetectsInPlaceMutation():Void {
		final data = markedData();
		final family = new TestEnvelopeFamily(ExactBodyRevision, [MutateBodyInPlace.ID => Preserve]);
		FunctionBodyRevision.resetDigestCallCount();
		final error = expectLifecycleError(() -> lifecycle(family).process(data, compiler(), [Custom(new MutateBodyInPlace())]));
		if (error.code != "reflaxe:semantic-contract-violation" || FunctionBodyRevision.getDigestCallCount() < 2) {
			Context.fatalError("an exact-body lifecycle did not detect an in-place body change", Context.currentPos());
		}
	}

	static function assertTraceIsOutputInert():Void {
		final quietData = markedData();
		final tracedData = markedData();
		final repeatedTraceData = markedData();
		final quietFamily = new TestEnvelopeFamily(StructuralEnvelope, [NoOp.ID => Preserve]);
		final tracedFamily = new TestEnvelopeFamily(StructuralEnvelope, [NoOp.ID => Preserve]);
		final quiet = lifecycle(quietFamily, false);
		final traced = lifecycle(tracedFamily, true);
		final repeatedTrace = lifecycle(new TestEnvelopeFamily(StructuralEnvelope, [NoOp.ID => Preserve]), true);
		quiet.process(quietData, compiler(), [Custom(new NoOp())]);
		traced.process(tracedData, compiler(), [Custom(new NoOp())]);
		repeatedTrace.process(repeatedTraceData, compiler(), [Custom(new NoOp())]);
		if (quiet.getTrace().length != 0 || traced.getTrace().length == 0) {
			Context.fatalError("semantic trace capture did not obey its opt-in", Context.currentPos());
		}
		if (quietData.bodyRevision.id != tracedData.bodyRevision.id
			|| TypedExprTools.toString(quietData.expr) != TypedExprTools.toString(tracedData.expr)) {
			Context.fatalError("semantic trace capture changed the function body or revision", Context.currentPos());
		}
		if (haxe.Json.stringify(traced.getTrace()) != haxe.Json.stringify(repeatedTrace.getTrace())) {
			Context.fatalError("semantic lifecycle trace was not deterministic", Context.currentPos());
		}
	}

	static function lifecycle(family:SemanticArtifactFamily, captureTrace:Bool = false):SemanticLifecycle {
		final result = new SemanticLifecycle({
			families: [family],
			pipelineRevision: "semantic-lifecycle-test-v1",
			captureTrace: captureTrace
		});
		result.beginProgram();
		return result;
	}

	static function compiler():BaseCompiler {
		return new TestCompiler();
	}

	static function markedData():ClassFuncData {
		final effect = Context.typeExpr(macro Sys.println("semantic effect"));
		final metadata:MetadataEntry = {
			name: TestEnvelopeFamily.METADATA,
			params: [],
			pos: Context.currentPos()
		};
		final marked:TypedExpr = {
			expr: TMeta(metadata, effect),
			pos: effect.pos,
			t: effect.t
		};
		final resolved = testMethod();
		ClassFieldHelper.resetDataCaches();
		final data = resolved.field.findFuncData(resolved.cls, true);
		if (data == null) {
			Context.fatalError("test method data was not available", Context.currentPos());
		}
		data.setExpr(marked);
		data.bindProgramRevision("semantic-lifecycle-test-program");
		return data;
	}

	static function testMethod():{cls:ClassType, field:haxe.macro.Type.ClassField} {
		return switch (Context.getType("MyClass")) {
			case TInst(reference, _):
				final cls = reference.get();
				final field = cls.statics.get().filter(candidate -> candidate.name == "testMod")[0];
				{cls: cls, field: field};
			case _:
				Context.fatalError("MyClass did not resolve to a class", Context.currentPos());
		}
	}

	static function moduleType(name:String):ModuleType {
		return typeAsModuleType(Context.getType(name));
	}

	static function typeAsModuleType(type:haxe.macro.Type):ModuleType {
		return switch (type) {
			case TInst(reference, _): TClassDecl(reference);
			case TEnum(reference, _): TEnumDecl(reference);
			case TType(reference, _): TTypeDecl(reference);
			case TAbstract(reference, _): TAbstract(reference);
			case _: Context.fatalError("type did not resolve to a module declaration", Context.currentPos());
		}
	}

	static function moduleTypeAsType(moduleType:ModuleType):haxe.macro.Type {
		return switch (moduleType) {
			case TClassDecl(reference): TInst(reference, []);
			case TEnumDecl(reference): TEnum(reference, []);
			case TTypeDecl(reference): TType(reference, []);
			case TAbstract(reference): TAbstract(reference, []);
		}
	}

	static function expectLifecycleError(run:() -> Void):SemanticLifecycleError {
		try {
			run();
		} catch (error:SemanticLifecycleError) {
			return error;
		}
		return Context.fatalError("expected a semantic lifecycle error", Context.currentPos());
	}

	static function expectMessage(run:() -> Void):String {
		try {
			run();
		} catch (error:haxe.Exception) {
			return error.message;
		} catch (error:Dynamic) {
			return Std.string(error);
		}
		return Context.fatalError("expected a lexical-local identity error", Context.currentPos());
	}
	#end
}

#if macro
private class TestEnvelopeFamily extends SemanticArtifactFamily {
	public static inline final ID = "test.semantic-envelope";
	public static inline final METADATA = ":testSemanticEnvelope";

	final actions:Map<String, SemanticPreprocessorAction>;

	public function new(binding:SemanticArtifactBinding, actions:Map<String, SemanticPreprocessorAction>) {
		super(ID, binding);
		this.actions = actions;
	}

	public function snapshot(data:ClassFuncData):Array<SemanticArtifactSnapshot> {
		final result:Array<SemanticArtifactSnapshot> = [];
		if (data.expr == null) {
			return result;
		}
		var ordinal = 0;
		function visit(expression:TypedExpr):Void {
			switch (expression.expr) {
				case TMeta(metadata, inner) if (metadata.name == METADATA):
					result.push({
						id: 'origin-${ordinal++}',
						fingerprint: TypedExprTools.toString(inner),
						origin: "synthetic-test"
					});
				case _:
			}
			TypedExprTools.iter(expression, visit);
		}
		visit(data.expr);
		return result;
	}

	public function actionFor(preprocessorId:String):SemanticPreprocessorAction {
		return actions.get(preprocessorId) ?? Reject;
	}

	override public function mapReplacement(preprocessorId:String, before:Array<SemanticArtifactSnapshot>,
			after:Array<SemanticArtifactSnapshot>):Null<Array<SemanticArtifactReplacement>> {
		final result:Array<SemanticArtifactReplacement> = [];
		final remainingAfter:Map<String, Bool> = [for (artifact in after) artifact.id => true];
		for (artifact in before) {
			if (remainingAfter.exists(artifact.id)) {
				result.push({beforeId: artifact.id, afterId: artifact.id});
				remainingAfter.remove(artifact.id);
			} else {
				result.push({beforeId: artifact.id, afterId: null});
			}
		}
		for (artifact in after) {
			if (remainingAfter.exists(artifact.id)) {
				result.push({beforeId: null, afterId: artifact.id});
			}
		}
		return result;
	}
}

private class DropEnvelope extends BasePreprocessor {
	public static inline final ID = "test.drop-envelope";

	public function new() {}

	override public function semanticLifecycleId():String
		return ID;

	public function process(data:ClassFuncData, compiler:BaseCompiler):Void {
		if (data.expr == null)
			return;
		switch (data.expr.expr) {
			case TMeta(_, inner):
				data.setExpr(inner);
			case _:
		}
	}
}

private class RebuildEnvelope extends BasePreprocessor {
	public static inline final ID = "test.rebuild-envelope";

	public function new() {}

	override public function semanticLifecycleId():String
		return ID;

	public function process(data:ClassFuncData, compiler:BaseCompiler):Void {
		if (data.expr == null)
			return;
		final metadata:MetadataEntry = {
			name: TestEnvelopeFamily.METADATA,
			params: [],
			pos: data.expr.pos
		};
		data.setExpr({expr: TMeta(metadata, data.expr), pos: data.expr.pos, t: data.expr.t});
	}
}

private class WrapRoot extends BasePreprocessor {
	public static inline final ID = "test.wrap-root";

	public function new() {}

	override public function semanticLifecycleId():String
		return ID;

	public function process(data:ClassFuncData, compiler:BaseCompiler):Void {
		if (data.expr == null)
			return;
		data.setExpr({expr: TParenthesis(data.expr), pos: data.expr.pos, t: data.expr.t});
	}
}

private class NoOp extends BasePreprocessor {
	public static inline final ID = "test.no-op";

	public function new() {}

	override public function semanticLifecycleId():String
		return ID;

	public function process(data:ClassFuncData, compiler:BaseCompiler):Void {}
}

private class MutateBodyInPlace extends BasePreprocessor {
	public static inline final ID = "test.mutate-body-in-place";

	public function new() {}

	override public function semanticLifecycleId():String
		return ID;

	public function process(data:ClassFuncData, compiler:BaseCompiler):Void {
		if (data.expr == null)
			return;
		final child:TypedExpr = {expr: data.expr.expr, pos: data.expr.pos, t: data.expr.t};
		data.expr.expr = TParenthesis(child);
	}
}
#end
