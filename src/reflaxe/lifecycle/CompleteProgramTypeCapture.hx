package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.macro.Context;
import haxe.macro.Type;
import haxe.macro.Type.ModuleType;

using reflaxe.helpers.ModuleTypeHelper;

/**
	Captures the complete declaration set Haxe supplies for one generation request.

	`Context.onGenerate` exposes declarations as `Type` values even though Reflaxe
	compilers consume `ModuleType` declarations. `replace` performs that narrow
	conversion, rejects malformed or duplicate declarations, and supersedes any
	unconsumed capture left by a failed earlier request. `take` consumes the
	current request exactly once so mutable host references cannot silently leak
	into a later target run.
**/
class CompleteProgramTypeCapture {
	var captured:Null<Array<ModuleType>>;

	public function new() {}

	/**
		Replaces any stale request with a defensively copied complete program.

		Haxe constructs the callback input by converting its complete module-type
		list, so only declaration-shaped `Type` variants are valid here.
	**/
	public function replace(types:Array<Type>):Void {
		final next:Array<ModuleType> = [];
		final seen:Map<String, Bool> = [];
		for (type in types) {
			final moduleType = toModuleType(type);
			final id = moduleType.getUniqueId();
			if (seen.exists(id)) {
				throw new SemanticLifecycleError("reflaxe:duplicate-complete-program-type",
					'The complete Haxe generation view contained declaration "$id" more than once.');
			}
			seen.set(id, true);
			next.push(moduleType);
		}
		captured = orderDeclarations(next);
	}

	/**
		Consumes the current complete program and clears all retained references.
	**/
	public function take():Array<ModuleType> {
		final current = captured;
		if (current == null) {
			throw new SemanticLifecycleError("reflaxe:missing-complete-program",
				"Haxe did not provide a complete onGenerate declaration view for this target request.");
		}
		captured = null;
		return current.copy();
	}

	static function toModuleType(type:Type):ModuleType {
		return switch (type) {
			case TInst(reference, _): TClassDecl(reference);
			case TEnum(reference, _): TEnumDecl(reference);
			case TType(reference, _): TTypeDecl(reference);
			case TAbstract(reference, _): TAbstract(reference);
			case _:
				throw new SemanticLifecycleError("reflaxe:malformed-complete-program-type",
					"Haxe's complete generation view contained a value that was not a module declaration.");
		}
	}

	/**
		Restores source declaration order inside each Haxe module.

		Haxe's complete `onGenerate` view can present secondary declarations in a
		different order from the earlier typed-module callback. Target backends may
		use same-module order to place type-dependent storage safely, so the
		complete-program cut must not silently change that behavior. The first
		appearance of each module still owns cross-module order; only declarations
		from that same source module are normalized.
	**/
	static function orderDeclarations(declarations:Array<ModuleType>):Array<ModuleType> {
		final moduleOrder:Array<String> = [];
		final byModule:Map<String, Array<{
			declaration:ModuleType,
			min:Int,
			max:Int,
			hostIndex:Int
		}>> = [];
		for (hostIndex => declaration in declarations) {
			final common = declaration.getCommonData();
			if (!byModule.exists(common.module)) {
				byModule.set(common.module, []);
				moduleOrder.push(common.module);
			}
			final position = Context.getPosInfos(common.pos);
			byModule[common.module].push({
				declaration: declaration,
				min: position.min,
				max: position.max,
				hostIndex: hostIndex
			});
		}

		final ordered:Array<ModuleType> = [];
		for (moduleId in moduleOrder) {
			final entries = byModule[moduleId];
			entries.sort((left, right) -> {
				if (left.min != right.min)
					return left.min - right.min;
				if (left.max != right.max)
					return left.max - right.max;
				return left.hostIndex - right.hostIndex;
			});
			for (entry in entries)
				ordered.push(entry.declaration);
		}
		return ordered;
	}
}
#end
