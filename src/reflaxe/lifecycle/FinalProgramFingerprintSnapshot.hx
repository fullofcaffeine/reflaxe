package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.ds.ObjectMap;
import haxe.macro.Expr;
import haxe.macro.Expr.Metadata;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import haxe.macro.Type.ClassField;
import haxe.macro.Type.ModuleType;
import haxe.macro.Type.TypeParameter;
import haxe.macro.Type.TypedExpr;
import haxe.macro.TypedExprTools;
import reflaxe.helpers.Context;
import sys.FileSystem;
import sys.io.File;

using reflaxe.helpers.ModuleTypeHelper;
using reflaxe.helpers.TypeHelper;

/**
	Immutable, host-neutral revision snapshot of the final selected Haxe program.

	The snapshot is built after target-neutral filtering and before target
	preparation. It records ordered declaration membership, conservative public
	and implementation revisions, selected source origins and contents, and
	host request inputs available through Haxe's public macro API. It retains no
	`ModuleType`, `ClassField`, `TypedExpr`, `Type`, `Position`, or other mutable
	host object.

	This snapshot is necessary but not sufficient for target reuse. A target must
	still add exact framework, target implementation, configuration, macro realm,
	runtime, output-schema, ambient-input, and diagnostics eligibility revisions.
**/
class FinalProgramFingerprintSnapshot {
	public static inline final SCHEMA_REVISION = "reflaxe-final-program-fingerprint-v2";

	public final id:String;
	public final programMembershipRevision:String;
	public final hostRequestRevision:String;
	public final programRevision:ProgramRevision;
	public final sourceAuthorityComplete:Bool;

	final declarationValues:Array<FinalProgramDeclarationFingerprint>;
	final sourceAuthorityBlockerValues:Array<String>;

	@:allow(reflaxe.lifecycle.FinalProgramFingerprintBuilder)
	function new(id:String, programMembershipRevision:String, hostRequestRevision:String, programRevision:ProgramRevision,
			declarations:Array<FinalProgramDeclarationFingerprint>, sourceAuthorityComplete:Bool, sourceAuthorityBlockers:Array<String>) {
		this.id = id;
		this.programMembershipRevision = programMembershipRevision;
		this.hostRequestRevision = hostRequestRevision;
		this.programRevision = programRevision;
		this.declarationValues = declarations.copy();
		this.sourceAuthorityComplete = sourceAuthorityComplete;
		this.sourceAuthorityBlockerValues = sourceAuthorityBlockers.copy();
	}

	/**
		Builds one snapshot without repeating final typed-body digests.

		The same body observations feed the compatibility `ProgramRevision` and
		the richer declaration revisions. This keeps the future reuse probe from
		adding a second compiler-sized typed-expression walk.
	**/
	public static function fromModuleTypes(moduleTypes:Array<ModuleType>):FinalProgramFingerprintSnapshot {
		return new FinalProgramFingerprintBuilder().build(moduleTypes);
	}

	/** Returns a defensive copy of the ordered plain-value declarations. **/
	public function declarations():Array<FinalProgramDeclarationFingerprint> {
		return declarationValues.copy();
	}

	/** Returns stable authority blockers without exposing mutable snapshot state. **/
	public function sourceAuthorityBlockers():Array<String> {
		return sourceAuthorityBlockerValues.copy();
	}
}

private class FinalProgramFingerprintBuilder {
	final sourceRevisionByFile:Map<String, String> = [];
	final sourceAuthorityBlockers:Array<String> = [];
	final compatibilityEntries:Array<String> = ["program-revision-schema|2"];
	final bodyRevisionByField:ObjectMap<ClassField, String> = new ObjectMap();
	final compilerMainPosition:Null<Position>;
	var functionCount = 0;

	public function new() {
		compilerMainPosition = findCompilerMainPosition();
	}

	public function build(moduleTypes:Array<ModuleType>):FinalProgramFingerprintSnapshot {
		final declarations:Array<FinalProgramDeclarationFingerprint> = [];
		for (moduleType in moduleTypes)
			declarations.push(declarationFingerprint(moduleType));

		final membership = new CanonicalFingerprint("reflaxe-program-membership-v1");
		membership.addInt("declaration-count", declarations.length);
		for (index => declaration in declarations) {
			membership.addInt("index", index);
			membership.add("identity", declaration.identity);
			membership.add("module", declaration.moduleIdentity);
			membership.add("kind", declaration.kind);
			membership.add("source-origin", declaration.sourceOriginRevision);
		}
		final membershipRevision = membership.digest();
		final hostRevision = hostRequestRevision();
		final compatibility = ProgramRevision.fromCompatibilityEntries(compatibilityEntries, moduleTypes.length, functionCount);
		final complete = new CanonicalFingerprint(FinalProgramFingerprintSnapshot.SCHEMA_REVISION);
		complete.add("membership", membershipRevision);
		complete.add("host-request", hostRevision);
		complete.add("compatibility-program", compatibility.id);
		for (declaration in declarations) {
			complete.add("declaration", declaration.identity);
			complete.add("public-api", declaration.publicApiRevision);
			complete.add("implementation", declaration.implementationRevision);
		}
		final blockers = sourceAuthorityBlockers.copy();
		blockers.sort(Reflect.compare);
		return new FinalProgramFingerprintSnapshot(complete.digest(), membershipRevision, hostRevision, compatibility, declarations, blockers.length == 0,
			blockers);
	}

	function declarationFingerprint(moduleType:ModuleType):FinalProgramDeclarationFingerprint {
		final common = moduleType.getCommonData();
		final identity = moduleType.getUniqueId();
		final moduleIdentity = common.module;
		final kind = switch (moduleType) {
			case TClassDecl(_): "class";
			case TEnumDecl(_): "enum";
			case TTypeDecl(_): "typedef";
			case TAbstract(_): "abstract";
		};
		final sourceOrigin = positionRevision(common.pos, common.module);
		final publicApi = new CanonicalFingerprint("reflaxe-declaration-public-api-v1");
		final implementation = new CanonicalFingerprint("reflaxe-declaration-implementation-v1");
		addBaseType(publicApi, common);
		addBaseType(implementation, common);
		implementation.add("source-origin", sourceOrigin);

		compatibilityEntries.push('module|$identity');
		switch (moduleType) {
			case TClassDecl(reference):
				final cls = reference.get();
				addClass(publicApi, implementation, identity, cls);
			case TEnumDecl(reference):
				final enumType = reference.get();
				for (name in enumType.names) {
					final field = enumType.constructs.get(name);
					if (field == null)
						continue;
					publicApi.add("enum-constructor", enumFieldRevision(field));
					implementation.add("enum-constructor", enumFieldRevision(field));
					compatibilityEntries.push('$identity|enum|$name|${field.type.getCanonicalId()}');
				}
			case TTypeDecl(reference):
				final type = reference.get().type.getCanonicalId();
				publicApi.add("typedef-type", type);
				implementation.add("typedef-type", type);
				compatibilityEntries.push('$identity|typedef|$type');
			case TAbstract(reference):
				final abstractType = reference.get();
				final underlyingType = abstractType.type.getCanonicalId();
				publicApi.add("underlying-type", underlyingType);
				implementation.add("underlying-type", underlyingType);
				addAbstract(publicApi, implementation, identity, abstractType);
				compatibilityEntries.push('$identity|abstract|$underlyingType');
		}

		return new FinalProgramDeclarationFingerprint(identity, moduleIdentity, kind, sourceOrigin, publicApi.digest(), implementation.digest());
	}

	function addBaseType(target:CanonicalFingerprint, type:BaseType):Void {
		target.add("package", type.pack.join("."));
		target.add("name", type.name);
		target.add("module", type.module);
		target.addBool("private", type.isPrivate);
		target.addBool("extern", type.isExtern);
		target.add("parameters", typeParametersRevision(type.params));
		target.add("metadata", metadataRevision(type.meta.get()));
		target.add("documentation", type.doc ?? "");
	}

	function addClass(publicApi:CanonicalFingerprint, implementation:CanonicalFingerprint, owner:String, cls:ClassType):Void {
		for (target in [publicApi, implementation]) {
			target.add("class-kind", classKindRevision(cls.kind));
			target.addBool("interface", cls.isInterface);
			target.addBool("final", cls.isFinal);
			target.addBool("abstract", cls.isAbstract);
			target.add("superclass", cls.superClass == null ? "" : typedClassReferenceRevision(cls.superClass));
			for (entry in cls.interfaces)
				target.add("interface-type", typedClassReferenceRevision(entry));
		}

		if (cls.constructor != null)
			addClassField(publicApi, implementation, owner, "constructor", cls.constructor.get());
		for (field in cls.fields.get())
			addClassField(publicApi, implementation, owner, "instance", field);
		for (field in cls.statics.get())
			addClassField(publicApi, implementation, owner, "static", field);
		for (field in cls.overrides)
			implementation.add("override", field.get().name);
		implementation.add("class-init", expressionRevision(cls.init));
	}

	function addAbstract(publicApi:CanonicalFingerprint, implementation:CanonicalFingerprint, owner:String, abstractType:AbstractType):Void {
		publicApi.add("implementation-class", abstractType.impl == null ? "" : classIdentity(abstractType.impl.get()));
		implementation.add("implementation-class", abstractType.impl == null ? "" : classIdentity(abstractType.impl.get()));
		for (entry in abstractType.binops) {
			publicApi.add("binary-operator", '${Std.string(entry.op)}|${fieldReferenceRevision(entry.field)}');
			implementation.add("binary-operator", '${Std.string(entry.op)}|${fieldReferenceRevision(entry.field)}');
		}
		for (entry in abstractType.unops) {
			publicApi.add("unary-operator", '${Std.string(entry.op)}|${entry.postFix}|${fieldReferenceRevision(entry.field)}');
			implementation.add("unary-operator", '${Std.string(entry.op)}|${entry.postFix}|${fieldReferenceRevision(entry.field)}');
		}
		for (entry in abstractType.from) {
			publicApi.add("from-cast", '${entry.t.getCanonicalId()}|${fieldReferenceRevision(entry.field)}');
			implementation.add("from-cast", '${entry.t.getCanonicalId()}|${fieldReferenceRevision(entry.field)}');
		}
		for (entry in abstractType.to) {
			publicApi.add("to-cast", '${entry.t.getCanonicalId()}|${fieldReferenceRevision(entry.field)}');
			implementation.add("to-cast", '${entry.t.getCanonicalId()}|${fieldReferenceRevision(entry.field)}');
		}
		for (field in abstractType.array) {
			publicApi.add("array-access", fieldReferenceRevision(field));
			implementation.add("array-access", fieldRevision(owner, "abstract-array", field, bodyRevision(field)));
		}
		publicApi.add("resolve", fieldReferenceRevision(abstractType.resolve, true));
		publicApi.add("resolve-write", fieldReferenceRevision(abstractType.resolveWrite, true));
		implementation.add("resolve", fieldReferenceRevision(abstractType.resolve, true));
		implementation.add("resolve-write", fieldReferenceRevision(abstractType.resolveWrite, true));

		if (abstractType.impl != null) {
			for (field in abstractType.impl.get().statics.get())
				addClassField(publicApi, implementation, owner, "abstract-static", field);
		}
	}

	function addClassField(publicApi:CanonicalFingerprint, implementation:CanonicalFingerprint, owner:String, category:String, field:ClassField):Void {
		final body = bodyRevision(field);
		final revision = fieldRevision(owner, category, field, body);
		if (field.isPublic)
			publicApi.add("field", revision);
		implementation.add("field", revision);
		compatibilityEntries.push('$owner|$category|${field.name}|${field.type.getCanonicalId()}|$body');
		switch (field.kind) {
			case FMethod(_):
				functionCount += 1;
			case _:
		}
	}

	function fieldRevision(owner:String, category:String, field:ClassField, bodyRevision:String):String {
		final result = new CanonicalFingerprint("reflaxe-class-field-v1");
		result.add("owner", owner);
		result.add("category", category);
		result.add("name", field.name);
		result.add("type", field.type.getCanonicalId());
		result.addBool("public", field.isPublic);
		result.addBool("extern", field.isExtern);
		result.addBool("final", field.isFinal);
		result.addBool("abstract", field.isAbstract);
		result.add("parameters", typeParametersRevision(field.params));
		result.add("metadata", metadataRevision(field.meta.get(), isCompilerMainField(field) ? field.pos : null));
		result.add("kind", fieldKindRevision(field.kind));
		result.add("body", bodyRevision);
		result.add("position", positionRevision(field.pos, owner + "." + field.name));
		result.add("documentation", field.doc ?? "");
		for (overloadField in field.overloads.get())
			result.add("overload", shallowFieldRevision(overloadField));
		return result.digest();
	}

	function bodyRevision(field:ClassField):String {
		final cached = bodyRevisionByField.get(field);
		if (cached != null)
			return cached;
		final expression = field.expr();
		final revision = expression != null ? NormalizedProgramBodyDigest.digestExpression(expression) : "<bodiless>";
		bodyRevisionByField.set(field, revision);
		return revision;
	}

	function shallowFieldRevision(field:ClassField):String {
		final result = new CanonicalFingerprint("reflaxe-overload-field-v1");
		result.add("name", field.name);
		result.add("type", field.type.getCanonicalId());
		result.addBool("public", field.isPublic);
		result.addBool("extern", field.isExtern);
		result.addBool("final", field.isFinal);
		result.addBool("abstract", field.isAbstract);
		result.add("parameters", typeParametersRevision(field.params));
		result.add("metadata", metadataRevision(field.meta.get(), isCompilerMainField(field) ? field.pos : null));
		result.add("kind", fieldKindRevision(field.kind));
		result.add("body", bodyRevision(field));
		return result.digest();
	}

	function enumFieldRevision(field:EnumField):String {
		final result = new CanonicalFingerprint("reflaxe-enum-field-v1");
		result.add("name", field.name);
		result.add("type", field.type.getCanonicalId());
		result.addInt("index", field.index);
		result.add("parameters", typeParametersRevision(field.params));
		result.add("metadata", metadataRevision(field.meta.get()));
		result.add("position", positionRevision(field.pos, field.name));
		result.add("documentation", field.doc ?? "");
		return result.digest();
	}

	function typeParametersRevision(parameters:Array<TypeParameter>):String {
		final result = new CanonicalFingerprint("reflaxe-type-parameters-v1");
		for (parameter in parameters) {
			result.add("name", parameter.name);
			result.add("type", parameter.t.getCanonicalId());
			result.add("default", parameter.defaultType == null ? "" : parameter.defaultType.getCanonicalId());
		}
		return result.digest();
	}

	function metadataRevision(metadata:Metadata, compilerMainPosition:Null<Position> = null):String {
		final result = new CanonicalFingerprint("reflaxe-metadata-v1");
		for (entry in metadata) {
			if (compilerMainPosition != null && isCompilerOwnedMainKeep(entry, compilerMainPosition))
				continue;
			result.add("name", entry.name);
			for (parameter in entry.params ?? [])
				result.add("parameter", ExprTools.toString(parameter));
			result.add("position", positionRevision(entry.pos, entry.name));
		}
		return result.digest();
	}

	/**
		Finds the exact field called by Haxe's generated main expression.

		Haxe 4.3.7 adds a zero-width `@:keep` to this field during every
		finalization. Cached server requests can therefore expose duplicate
		compiler-owned entries even though source, typing, and output are
		unchanged. The field identity lets metadata normalization ignore only
		that host marker instead of ignoring user-authored `@:keep` generally.
	**/
	function findCompilerMainPosition():Null<Position> {
		final mainExpression = Context.getMainExpr();
		if (mainExpression == null)
			return null;
		var result:Null<Position> = null;
		function visit(expression:TypedExpr):Void {
			if (result != null)
				return;
			switch (expression.expr) {
				case TField(_, access):
					switch (access) {
						case FStatic(_, field) if (field.get().name == "main"):
							result = field.get().pos;
						case _:
					}
				case _:
			}
			if (result == null)
				TypedExprTools.iter(expression, visit);
		}
		visit(mainExpression);
		return result;
	}

	function isCompilerMainField(field:ClassField):Bool {
		if (field.name != "main" || compilerMainPosition == null)
			return false;
		try {
			final candidate = Context.getPosInfos(field.pos);
			final expected = Context.getPosInfos(compilerMainPosition);
			return candidate.min == expected.min
				&& candidate.max == expected.max
				&& normalizedFile(candidate.file) == normalizedFile(expected.file);
		} catch (_:Dynamic) {
			return false;
		}
	}

	function isCompilerOwnedMainKeep(entry:MetadataEntry, mainPosition:Position):Bool {
		if (entry.name != ":keep" || (entry.params ?? []).length != 0)
			return false;
		try {
			final entryPosition = Context.getPosInfos(entry.pos);
			final fieldPosition = Context.getPosInfos(mainPosition);
			return entryPosition.min == entryPosition.max
				&& entryPosition.min == fieldPosition.min
				&& normalizedFile(entryPosition.file) == normalizedFile(fieldPosition.file);
		} catch (_:Dynamic) {
			return false;
		}
	}

	inline function normalizedFile(file:Null<String>):String
		return StringTools.replace(file ?? "", "\\", "/");

	function classKindRevision(kind:ClassKind):String {
		return switch (kind) {
			case KNormal: "normal";
			case KTypeParameter(constraints): "type-parameter|" + constraints.map(type -> type.getCanonicalId()).join("|");
			case KModuleFields(module): "module-fields|" + module;
			case KExpr(expression): "expression|" + ExprTools.toString(expression);
			case KGeneric: "generic";
			case KGenericInstance(reference, parameters):
				"generic-instance|"
				+ classIdentity(reference.get())
				+ "|"
				+ parameters.map(type -> type.getCanonicalId()).join("|");
			case KMacroType: "macro-type";
			case KAbstractImpl(reference): "abstract-implementation|" + reference.get().module + "." + reference.get().name;
			case KGenericBuild: "generic-build";
		}
	}

	function fieldKindRevision(kind:FieldKind):String {
		return switch (kind) {
			case FVar(read, write): 'variable|${Std.string(read)}|${Std.string(write)}';
			case FMethod(methodKind): 'method|${Std.string(methodKind)}';
		}
	}

	function typedClassReferenceRevision(reference:{t:Ref<ClassType>, params:Array<Type>}):String {
		return classIdentity(reference.t.get()) + "|" + reference.params.map(type -> type.getCanonicalId()).join("|");
	}

	function classIdentity(cls:ClassType):String {
		return (cls.pack ?? []).concat([cls.name]).join(".");
	}

	function fieldReferenceRevision(field:Null<ClassField>, allowHostResolveSentinel = false):String {
		if (field == null)
			return "";

		/*
			Haxe 4.3.7 represents some abstract `@:op(a.b)` resolve hooks with a
			non-null ClassField placeholder whose own properties are all null.
			The placeholder means "this resolve hook exists"; it is not the same
			as an absent hook. Record that distinction without asking TypeTools to
			render the placeholder's null type.
		 */
		final name:Null<String> = cast field.name;
		final type:Null<Type> = cast field.type;
		final kind:Null<FieldKind> = cast field.kind;
		final isPublic:Null<Bool> = cast field.isPublic;
		final isExtern:Null<Bool> = cast field.isExtern;
		final isFinal:Null<Bool> = cast field.isFinal;
		final isAbstract:Null<Bool> = cast field.isAbstract;
		final parameters:Null<Array<TypeParameter>> = cast field.params;
		final metadata:Null<MetaAccess> = cast field.meta;
		final position:Null<Position> = cast field.pos;
		final documentation:Null<String> = cast field.doc;
		final overloads:Null<Ref<Array<ClassField>>> = cast field.overloads;
		final expressionProvider:Null<Void->Null<TypedExpr>> = cast field.expr;
		final isHostResolveSentinel = name == null && type == null && kind == null && isPublic == null && isExtern == null && isFinal == null
			&& isAbstract == null && parameters == null && metadata == null && position == null && documentation == null && overloads == null
			&& expressionProvider == null;
		if (allowHostResolveSentinel && isHostResolveSentinel)
			return "<host-resolve-field-sentinel>";

		/*
			A partially populated field is not a known host placeholder. Keep the
			snapshot build deterministic, but block target reuse because the key
			cannot prove the field's complete identity.
		 */
		if (name == null || type == null || kind == null) {
			sourceAuthorityBlockers.push("field-reference-incomplete");
			return "<incomplete-field-reference>";
		}
		return '$name|${type.getCanonicalId()}|${fieldKindRevision(kind)}';
	}

	function expressionRevision(expression:Null<TypedExpr>):String {
		return expression == null ? Sha256.encode("<bodiless>") : NormalizedProgramBodyDigest.digestExpression(expression);
	}

	function positionRevision(position:Position, owner:String):String {
		final result = new CanonicalFingerprint("reflaxe-source-position-v1");
		try {
			final info = Context.getPosInfos(position);
			final file = StringTools.replace(info.file ?? "", "\\", "/");
			result.add("file", file);
			result.addInt("minimum", info.min);
			result.addInt("maximum", info.max);
			result.add("source-content", sourceContentRevision(file, owner));
		} catch (error:Dynamic) {
			sourceAuthorityBlockers.push('position-unavailable:$owner');
			result.add("unavailable", Std.string(error));
		}
		return result.digest();
	}

	function sourceContentRevision(file:String, owner:String):String {
		final cached = sourceRevisionByFile.get(file);
		if (cached != null)
			return cached;

		final revision = if (file.length == 0) {
			Sha256.encode("<generated:no-file>");
		} else if (!FileSystem.exists(file)) {
			Sha256.encode("generated-origin|" + file);
		} else {
			try {
				Sha256.make(File.getBytes(file)).toHex();
			} catch (error:Dynamic) {
				sourceAuthorityBlockers.push('source-unreadable:$owner');
				Sha256.encode("unreadable-source|" + file + "|" + Std.string(error));
			}
		}
		sourceRevisionByFile.set(file, revision);
		return revision;
	}

	function hostRequestRevision():String {
		final result = new CanonicalFingerprint("reflaxe-host-request-v1");
		final defines = Context.getDefines();
		final defineNames = [for (name in defines.keys()) name];
		defineNames.sort(Reflect.compare);
		for (name in defineNames) {
			result.add("define-name", name);
			result.add("define-value", defines.get(name) ?? "");
		}
		for (classPath in Context.getClassPath())
			result.add("class-path", StringTools.replace(classPath, "\\", "/"));
		final resources = Context.getResources();
		final resourceNames = [for (name in resources.keys()) name];
		resourceNames.sort(Reflect.compare);
		for (name in resourceNames) {
			result.add("resource-name", name);
			final value = resources.get(name);
			result.add("resource-content", value == null ? "" : Sha256.make(value).toHex());
		}
		result.add("main-expression", expressionRevision(Context.getMainExpr()));
		return result.digest();
	}
}
#end
