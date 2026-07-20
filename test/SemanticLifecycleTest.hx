#if macro
import haxe.macro.Context;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.Type.ClassType;
import haxe.macro.Type.ModuleType;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.helpers.ClassFieldHelper;
import reflaxe.lifecycle.FunctionBodyRevision;
import reflaxe.lifecycle.ModuleTypeBatchAccumulator;
import reflaxe.lifecycle.ProgramRevision;
import reflaxe.lifecycle.SemanticArtifactBinding;
import reflaxe.lifecycle.SemanticArtifactFamily;
import reflaxe.lifecycle.SemanticArtifactReplacement;
import reflaxe.lifecycle.SemanticArtifactSnapshot;
import reflaxe.lifecycle.SemanticLifecycle;
import reflaxe.lifecycle.SemanticLifecycleError;
import reflaxe.lifecycle.SemanticPreprocessorAction;
import reflaxe.preprocessors.BasePreprocessor;
import reflaxe.preprocessors.ExpressionPreprocessor;

using reflaxe.helpers.ClassFieldHelper;
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
		assertTypingBatchesAccumulate();
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

	static function assertTypingBatchesAccumulate():Void {
		final accumulator = new ModuleTypeBatchAccumulator();
		final first = moduleType("MyClass");
		final second = moduleType("LazyAddedType");
		accumulator.add([first]);
		accumulator.add([first, second]);
		final accumulated = accumulator.take();
		if (accumulated.length != 2 || accumulated[0] != first || accumulated[1] != second) {
			Context.fatalError("onAfterTyping batches were not reconciled in first-seen order", Context.currentPos());
		}
		if (accumulator.take().length != 0) {
			Context.fatalError("module-type accumulator retained objects across requests", Context.currentPos());
		}
		final forwardRevision = ProgramRevision.fromModuleTypes([first, second]);
		final reverseRevision = ProgramRevision.fromModuleTypes([second, first]);
		if (forwardRevision.id != reverseRevision.id) {
			Context.fatalError('program revision depended on module callback order: ${forwardRevision.id} != ${reverseRevision.id}', Context.currentPos());
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
		return switch (Context.getType(name)) {
			case TInst(reference, _): TClassDecl(reference);
			case _: Context.fatalError('$name did not resolve to a class', Context.currentPos());
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
