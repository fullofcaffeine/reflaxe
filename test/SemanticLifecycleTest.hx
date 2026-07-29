#if macro
import haxe.macro.Context;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.Type.ClassType;
import haxe.macro.Type.ModuleType;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import haxe.io.Path;
import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.helpers.ClassFieldHelper;
import reflaxe.lifecycle.CompleteProgramTypeCapture;
import reflaxe.lifecycle.FunctionBodyRevision;
import reflaxe.lifecycle.LexicalLocalIdentityPlan;
import reflaxe.lifecycle.NormalizedProgramBodyDigest;
import reflaxe.lifecycle.ProgramRevision;
import reflaxe.lifecycle.SemanticArtifactBinding;
import reflaxe.lifecycle.SemanticArtifactFamily;
import reflaxe.lifecycle.SemanticArtifactReplacement;
import reflaxe.lifecycle.SemanticArtifactSnapshot;
import reflaxe.lifecycle.SemanticLifecycle;
import reflaxe.lifecycle.SemanticLifecycleError;
import reflaxe.lifecycle.SemanticPreprocessorAction;
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
			var executed = false;
			Context.onAfterTyping(_ -> {
				if (!executed) {
					executed = true;
					execute();
				}
			});
		});
	}

	static function execute():Void {
		assertCompleteProgramCaptureOwnsTargetInput();
		assertDirectoryOutputTransactionRollsBack();
		assertLexicalLocalIdentitiesNormalizeHostIds();
		assertLexicalLocalIdentitiesRemainDistinct();
		assertLexicalLocalIdentityShapeFailsClosed();
		assertLexicalLocalIdentitiesFailClosed();
		assertProgramRevisionNormalizesHostLocalIds();
		assertProgramRevisionKeepsSemanticChanges();
		assertFunctionCacheIsRequestScoped();
		assertLifecycleSchemaFailsClosed();
		assertPreserveLossNamesTheOwner();
		assertInvalidationRequiresRebuild();
		assertInvalidationThenRebuildSucceeds();
		assertStructuralLifecycleDoesNotRehashEveryPass();
		assertExactBodyRevisionCannotSurviveReplacement();
		assertExactBodyRevisionDetectsInPlaceMutation();
		assertTraceIsOutputInert();
		ClassFieldHelper.resetDataCaches();
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
		if (captured.length != 2
			|| captured[0].getUniqueId() != first.getUniqueId()
			|| captured[1].getUniqueId() != second.getUniqueId()) {
			Context.fatalError("the complete onGenerate view did not replace a stale partial request defensively", Context.currentPos());
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

	static function assertLexicalLocalIdentityShapeFailsClosed():Void {
		final valid = LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "0", 64);
		if (!LexicalLocalIdentityPlan.isReusableId(valid)
			|| LexicalLocalIdentityPlan.isReusableId("17")
			|| LexicalLocalIdentityPlan.isReusableId(LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "0", 63))
			|| LexicalLocalIdentityPlan.isReusableId(LexicalLocalIdentityPlan.ID_PREFIX + StringTools.lpad("", "G", 64))) {
			Context.fatalError("lexical-local publication validation accepted a host ID or rejected one complete stable ID", Context.currentPos());
		}
	}

	static function assertLexicalLocalIdentitiesFailClosed():Void {
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
		final duplicate:TypedExpr = {
			expr: haxe.macro.Type.TypedExprDef.TBlock([block[0], block[0], block[1]]),
			pos: declared.pos,
			t: declared.t
		};
		final missing:TypedExpr = {
			expr: haxe.macro.Type.TypedExprDef.TBlock([block[1]]),
			pos: declared.pos,
			t: declared.t
		};
		final duplicateError = expectMessage(() -> LexicalLocalIdentityPlan.build("duplicate-owner", duplicate));
		final missingError = expectMessage(() -> LexicalLocalIdentityPlan.build("missing-owner", missing));
		if (duplicateError.indexOf("reflaxe:duplicate-lexical-local-binding") == -1
			|| missingError.indexOf("reflaxe:missing-lexical-local-identity") == -1) {
			Context.fatalError('lexical-local validation did not fail closed: duplicate=$duplicateError missing=$missingError', Context.currentPos());
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
