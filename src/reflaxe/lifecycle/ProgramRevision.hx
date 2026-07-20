package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.macro.Type.ClassField;
import haxe.macro.Type.ModuleType;

using reflaxe.helpers.ModuleTypeHelper;
using reflaxe.helpers.TypeHelper;

/**
	Path-independent identity for the final module and field set given to a target.

	This revision is computed after target type filtering. It deliberately records
	declaration identities, field signatures, and function body digests without
	retaining mutable host compiler objects.
**/
class ProgramRevision {
	public final id:String;
	public final moduleCount:Int;
	public final functionCount:Int;

	public function new(id:String, moduleCount:Int, functionCount:Int) {
		this.id = id;
		this.moduleCount = moduleCount;
		this.functionCount = functionCount;
	}

	/** Builds a deterministic revision from the target-selected program. **/
	public static function fromModuleTypes(moduleTypes:Array<ModuleType>):ProgramRevision {
		final entries:Array<String> = [];
		var functionCount = 0;

		function addField(owner:String, category:String, field:ClassField):Void {
			final expression = field.expr();
			final body = expression != null ? FunctionBodyRevision.digestExpression(expression) : "<bodiless>";
			entries.push('$owner|$category|${field.name}|${field.type.getCanonicalId()}|$body');
			switch (field.kind) {
				case FMethod(_):
					functionCount += 1;
				case _:
			}
		}

		for (moduleType in moduleTypes) {
			final moduleId = moduleType.getUniqueId();
			entries.push('module|$moduleId');
			switch (moduleType) {
				case TClassDecl(reference):
					final cls = reference.get();
					if (cls.constructor != null) {
						addField(moduleId, "constructor", cls.constructor.get());
					}
					for (field in cls.fields.get())
						addField(moduleId, "instance", field);
					for (field in cls.statics.get())
						addField(moduleId, "static", field);
				case TEnumDecl(reference):
					final enm = reference.get();
					for (name in enm.names) {
						final field = enm.constructs.get(name);
						if (field != null)
							entries.push('$moduleId|enum|$name|${field.type.getCanonicalId()}');
					}
				case TTypeDecl(reference):
					entries.push('$moduleId|typedef|${reference.get().type.getCanonicalId()}');
				case TAbstract(reference):
					final abstractType = reference.get();
					entries.push('$moduleId|abstract|${abstractType.type.getCanonicalId()}');
					for (field in abstractType.impl?.get().statics.get() ?? [])
						addField(moduleId, "abstract-static", field);
			}
		}

		entries.sort(Reflect.compare);
		return new ProgramRevision(Sha256.encode(entries.join("\n")), moduleTypes.length, functionCount);
	}
}
#end
