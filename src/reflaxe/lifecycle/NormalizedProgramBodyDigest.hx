package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.macro.Type.TypedExpr;

/**
	Creates a stable fingerprint for one Haxe function across compiler runs.

	Reflaxe includes this fingerprint in the program version used to reject stale
	compiler plans. Haxe's detailed expression text labels local variables with a
	process-wide number, such as `value(5378)`. Typing unrelated macro code first
	can change that label to `value(5380)` even though the function still behaves
	the same way. Hashing either label directly would make the program look changed.

	This class replaces only that unstable number with the local's order inside
	the current function. It keeps the rest of Haxe's detailed expression text, so
	changes to code, types, field access, or control flow still change the
	fingerprint. Two same-named variables in nested scopes remain distinct.
**/
class NormalizedProgramBodyDigest {
	/** Returns the stable fingerprint for one function body. **/
	public static function digestExpression(expression:TypedExpr):String {
		final rendered = #if macro haxe.macro.TypedExprTools.toString(expression) #else Std.string(expression.expr) #end;
		final normalized = normalizeLocalIds(rendered);
		#if macro
		final expectedOccurrences = countLocalOccurrences(expression);
		if (normalized.occurrenceCount != expectedOccurrences) {
			throw '[reflaxe:unsupported-program-revision-renderer] Haxe rendered $expectedOccurrences local-variable records, but Reflaxe recognized ${normalized.occurrenceCount}. Update the normalizer for this Haxe version instead of accepting unstable program fingerprints.';
		}
		#end
		return Sha256.encode(normalized.rendered);
	}

	/**
		Rewrites only IDs in Haxe's detailed `Local` and `Var` records.

		The scanner skips quoted strings so source literals that happen to contain
		debug-renderer text remain part of the digest exactly as authored.
	**/
	static function normalizeLocalIds(rendered:String):NormalizedLocalIds {
		final result = new StringBuf();
		final canonicalIds:Map<String, Int> = [];
		var nextCanonicalId = 0;
		var occurrenceCount = 0;
		var offset = 0;
		var inQuotedString = false;
		var escaped = false;

		while (offset < rendered.length) {
			final character = rendered.charAt(offset);
			if (inQuotedString) {
				result.add(character);
				if (escaped) {
					escaped = false;
				} else if (character == "\\") {
					escaped = true;
				} else if (character == '"') {
					inQuotedString = false;
				}
				offset += 1;
				continue;
			}

			if (character == '"') {
				inQuotedString = true;
				result.add(character);
				offset += 1;
				continue;
			}

			final idSpan = localIdSpanAt(rendered, offset);
			if (idSpan == null) {
				result.add(character);
				offset += 1;
				continue;
			}

			final hostId = rendered.substring(idSpan.start, idSpan.end);
			final parsedHostId = Std.parseInt(hostId);
			if (parsedHostId == null || Std.string(parsedHostId) != hostId) {
				result.add(character);
				offset += 1;
				continue;
			}

			var canonicalId = canonicalIds.get(hostId);
			if (canonicalId == null) {
				canonicalId = nextCanonicalId++;
				canonicalIds.set(hostId, canonicalId);
			}
			result.add(rendered.substring(offset, idSpan.start));
			result.add(canonicalId);
			occurrenceCount += 1;
			offset = idSpan.end;
		}

		return {rendered: result.toString(), occurrenceCount: occurrenceCount};
	}

	/**
		Locates the numeric ID in detailed local records from supported Haxe versions.

		Haxe 4 renders declarations as `Var name(id)`. Haxe 5 renders variables
		and function arguments as `Var name<id>(flags)` and `Arg name<id>(flags)`.
		Reads and the remaining binders use `Local name(id)` in both tested formats.
	**/
	static function localIdSpanAt(rendered:String, offset:Int):Null<{start:Int, end:Int}> {
		final localPrefix = "[Local ";
		if (rendered.substr(offset, localPrefix.length) == localPrefix) {
			final start = rendered.indexOf("(", offset + localPrefix.length) + 1;
			final end = start == 0 ? -1 : rendered.indexOf("):", start);
			return start == 0 || end == -1 ? null : {start: start, end: end};
		}

		var variablePrefix:Null<String> = null;
		for (prefix in ["[Var ", "[Arg "])
			if (rendered.substr(offset, prefix.length) == prefix) {
				variablePrefix = prefix;
				break;
			}
		if (variablePrefix == null)
			return null;

		final nameStart = offset + variablePrefix.length;
		final parenthesis = rendered.indexOf("(", nameStart);
		final angle = rendered.indexOf("<", nameStart);
		if (angle != -1 && (parenthesis == -1 || angle < parenthesis)) {
			final end = rendered.indexOf(">", angle + 1);
			return end == -1 ? null : {start: angle + 1, end: end};
		}
		if (parenthesis != -1) {
			final end = rendered.indexOf("):", parenthesis + 1);
			return end == -1 ? null : {start: parenthesis + 1, end: end};
		}
		return null;
	}

	#if macro
	/** Counts every local declaration, binder, and read that Haxe should render. **/
	static function countLocalOccurrences(expression:TypedExpr):Int {
		var result = 0;
		function visit(current:TypedExpr):Void {
			switch (current.expr) {
				case TLocal(_) | TVar(_, _):
					result += 1;
				case TFunction(func):
					result += func.args.length;
				case TFor(_, _, _):
					result += 1;
				case TTry(_, catches):
					result += catches.length;
				case _:
			}
			haxe.macro.TypedExprTools.iter(current, visit);
		}
		visit(expression);
		return result;
	}
	#end
}

private typedef NormalizedLocalIds = {
	final rendered:String;
	final occurrenceCount:Int;
}
#end
