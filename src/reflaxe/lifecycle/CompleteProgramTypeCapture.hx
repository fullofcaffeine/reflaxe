package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.macro.Type;
import haxe.macro.Type.ModuleType;
import reflaxe.helpers.Context;

using reflaxe.helpers.ModuleTypeHelper;

/**
	Captures the complete declaration set Haxe supplies for one generation request.

	`Context.onGenerate` exposes declarations as `Type` values even though Reflaxe
	compilers consume `ModuleType` declarations. `replace` performs that narrow
	conversion, rejects malformed or duplicate declarations, and gives every
	unchanged program the same target order even when Haxe's compilation server
	traverses modules differently. `replace` also supersedes any unconsumed
	capture left by a failed earlier request. `take` consumes the current request
	exactly once so mutable host references cannot silently leak into a later
	target run.
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

		Haxe has finished its built-in generation before Reflaxe calls `take`, so
		the captured declarations now contain the reachability flags that targets
		can inspect. Their compiler-server order is normalized on the same objects
		before they are returned. The target and its fingerprint therefore read
		one identical input rather than normalizing only the cache key.
	**/
	public function take():Array<ModuleType> {
		final current = captured;
		if (current == null) {
			throw new SemanticLifecycleError("reflaxe:missing-complete-program",
				"Haxe did not provide a complete onGenerate declaration view for this target request.");
		}
		captured = null;
		CompilerReachabilityMetadataOrder.normalizeProgram(current);
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
		Builds one deterministic target input from Haxe's complete declaration set.

		Haxe's compilation server can return the same source modules in a different
		cross-module traversal order on a later unchanged request. That traversal
		order is compiler bookkeeping, not source-program behavior. Letting it
		reach a target would make identical programs produce different reuse keys
		and could also let target output depend on whether the compiler process was
		cold or warm.

		Modules are therefore ordered by their stable Haxe module name. Declarations
		from one source module retain source-position order because targets can use
		that order for initialization and storage decisions. When position data
		cannot distinguish two declarations, their stable declaration identity—the
		declaration kind plus its fully qualified Haxe name—breaks the tie instead
		of the host callback index.
	**/
	static function orderDeclarations(declarations:Array<ModuleType>):Array<ModuleType> {
		final moduleOrder:Array<String> = [];
		final byModule:Map<String, Array<{
			declaration:ModuleType,
			identity:String,
			min:Int,
			max:Int
		}>> = [];
		for (declaration in declarations) {
			final common = declaration.getCommonData();
			var moduleDeclarations = byModule[common.module];
			if (moduleDeclarations == null) {
				moduleDeclarations = [];
				byModule.set(common.module, moduleDeclarations);
				moduleOrder.push(common.module);
			}
			final position = Context.getPosInfos(common.pos);
			moduleDeclarations.push({
				declaration: declaration,
				identity: declaration.getUniqueId(),
				min: position.min,
				max: position.max
			});
		}
		moduleOrder.sort(Reflect.compare);

		final ordered:Array<ModuleType> = [];
		for (moduleId in moduleOrder) {
			final entries = byModule[moduleId];
			if (entries == null) {
				throw new SemanticLifecycleError("reflaxe:missing-complete-program-module",
					'The normalized complete program lost declarations for module "$moduleId".');
			}
			entries.sort((left, right) -> {
				if (left.min != right.min)
					return left.min - right.min;
				if (left.max != right.max)
					return left.max - right.max;
				return Reflect.compare(left.identity, right.identity);
			});
			for (entry in entries)
				ordered.push(entry.declaration);
		}
		return ordered;
	}
}
#end
