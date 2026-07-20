package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.macro.Type.ModuleType;

using reflaxe.helpers.ModuleTypeHelper;

/**
	Collects every incremental `onAfterTyping` batch for one compilation.

	Haxe may invoke the callback repeatedly when a callback causes more types to
	load. Reflaxe must retain the first batch while replacing an earlier object
	with the newest object for the same stable module identity.
**/
class ModuleTypeBatchAccumulator {
	final orderedIds:Array<String> = [];
	final byId:Map<String, ModuleType> = [];

	public function new() {}

	/** Adds one incremental batch without discarding earlier types. **/
	public function add(moduleTypes:Array<ModuleType>):Void {
		for (moduleType in moduleTypes) {
			final id = moduleType.getUniqueId();
			if (!byId.exists(id)) {
				orderedIds.push(id);
			}
			byId.set(id, moduleType);
		}
	}

	/** Returns the accumulated types in first-seen order and starts a new request. **/
	public function take():Array<ModuleType> {
		final result:Array<ModuleType> = [for (id in orderedIds) cast byId.get(id)];
		reset();
		return result;
	}

	/** Drops all state, including references to mutable host compiler objects. **/
	public function reset():Void {
		orderedIds.resize(0);
		byId.clear();
	}
}
#end
