package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.Expr.Position;
import haxe.macro.Type.MetaAccess;
import haxe.macro.Type.ModuleType;
import reflaxe.helpers.Context;

using reflaxe.helpers.ModuleTypeHelper;

/**
	Gives Haxe's two reachability flags one target-visible order.

	Haxe represents dead-code-elimination results with empty `@:used` and
	`@:directlyUsed` metadata entries. A fresh compilation presents the direct
	flag before the used flag, but a long-lived compiler server can reverse that
	pair on cached declarations even when the program and reachability result are
	unchanged. Targets receive the metadata array, so normalizing only a cache
	key would be unsafe: a target could observe one order while the key describes
	another.

	This normalizer changes the actual `ModuleType` input before a Reflaxe target
	or its fingerprint reads it. It keeps both entries, duplicates, parameters,
	positions, and every unrelated metadata item. Only empty entries whose source
	range exactly matches Haxe's compiler-generated shape participate, and only
	their existing slots are reordered. Source annotations and uncertain
	positions remain untouched. Haxe 4.3.7 itself reads these flags with
	`Meta.has`, so their contract is set-like: presence matters and their mutual
	order does not.
**/
class CompilerReachabilityMetadataOrder {
	/**
		Normalizes class and enum declarations in one complete target request.

		Haxe 4.3.7 adds these reachability flags to top-level class and enum
		declarations. Abstracts, typedefs, fields, constructors, and overloads are
		intentionally not visited because Haxe does not add this reversible pair
		there and source macros may use the same metadata names. The operation is
		idempotent, so repeating it cannot keep changing the target input.
	**/
	public static function normalizeProgram(moduleTypes:Array<ModuleType>):Void {
		for (moduleType in moduleTypes) {
			switch (moduleType) {
				case TClassDecl(_) | TEnumDecl(_):
					final common = moduleType.getCommonData();
					normalizeMetadata(common.meta, common.pos);
				case TAbstract(_) | TTypeDecl(_):
			}
		}
	}

	static function normalizeMetadata(access:MetaAccess, ownerPosition:Position):Void {
		final current = access.get();
		final slots:Array<Int> = [];
		final markers:Array<MetadataEntry> = [];
		for (index => entry in current) {
			if (isCompilerReachabilityMarker(entry, ownerPosition)) {
				slots.push(index);
				markers.push(entry);
			}
		}
		if (markers.length < 2)
			return;
		final orderedMarkers = markers.filter(entry -> entry.name == ":directlyUsed");
		for (entry in markers) {
			if (entry.name == ":used")
				orderedMarkers.push(entry);
		}

		final normalized = current.copy();
		var changed = false;
		for (index => slot in slots) {
			if (normalized[slot].name != orderedMarkers[index].name)
				changed = true;
			normalized[slot] = orderedMarkers[index];
		}
		if (!changed)
			return;
		replaceMetadata(access, current, normalized);
	}

	/**
		Recognizes the source ranges Haxe assigns to its boolean DCE flags.

		An unavailable file or malformed range returns `false`, leaving the
		entry and its order unchanged. That conservative behavior may cause a
		cache miss, but it cannot hide uncertain input from a target.
	**/
	static function isCompilerReachabilityMarker(entry:MetadataEntry, ownerPosition:Position):Bool {
		if ((entry.name != ":used" && entry.name != ":directlyUsed") || (entry.params ?? []).length != 0)
			return false;
		try {
			final marker = Context.getPosInfos(entry.pos);
			final owner = Context.getPosInfos(ownerPosition);
			final markerFile = normalizedFile(marker.file);
			final ownerFile = normalizedFile(owner.file);
			if (markerFile.length == 0 || markerFile == "?" || ownerFile.length == 0 || ownerFile == "?" || markerFile != ownerFile || marker.min < 0
				|| marker.max < marker.min || owner.min < 0 || owner.max < owner.min) {
				return false;
			}
			return switch (entry.name) {
				case ":used": marker.min == marker.max && marker.min == owner.min;
				case ":directlyUsed": marker.min == owner.min && marker.max == owner.max;
				case _:
					false;
			}
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Rebuilds a `MetaAccess` without changing the requested final order.

		Haxe returns a copy from `MetaAccess.get`, so sorting that array alone
		would not affect the declaration a target receives. `add` prepends one
		entry; removing every current name and adding the final array in reverse
		recreates the same metadata list with only the selected slots changed.
	**/
	static function replaceMetadata(access:MetaAccess, current:Array<MetadataEntry>, normalized:Array<MetadataEntry>):Void {
		final removed:Map<String, Bool> = [];
		for (entry in current) {
			if (!removed.exists(entry.name)) {
				removed.set(entry.name, true);
				access.remove(entry.name);
			}
		}
		var index = normalized.length;
		while (index > 0) {
			index -= 1;
			final entry = normalized[index];
			access.add(entry.name, entry.params ?? [], entry.pos);
		}
	}

	static inline function normalizedFile(file:Null<String>):String
		return StringTools.replace(file ?? "", "\\", "/");
}
#end
