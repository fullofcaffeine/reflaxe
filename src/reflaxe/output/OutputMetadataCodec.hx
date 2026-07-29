package reflaxe.output;

#if (macro || reflaxe_runtime)
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import reflaxe.output.OutputManager.OutputMetadata;

/**
	Converts the persisted JSON receipt into validated output metadata.

	`haxe.Json.parse` necessarily returns `Dynamic`. This codec is the only
	boundary that handles that untrusted shape. Successful callers receive an
	`OutputMetadata` value whose scalar and file-list field types were checked.
**/
class OutputMetadataCodec {
	public static function decode(content:String, source:String):OutputMetadata {
		final fields:DynamicAccess<Dynamic> = try {
			cast Json.parse(content);
		} catch (cause:Dynamic) {
			throw malformed(source, 'cannot parse JSON: ${Std.string(cause)}');
		}
		if (fields == null) {
			throw malformed(source, "the JSON root is null");
		}

		final version = fields.get("version");
		final id = fields.get("id");
		final wasCached = fields.get("wasCached");
		final files = fields.get("filesGenerated");
		if (!Std.isOfType(version, Int) || !Std.isOfType(id, Int) || !Std.isOfType(wasCached, Bool) || !Std.isOfType(files, Array)) {
			throw malformed(source, "version, id, wasCached, or filesGenerated has the wrong type");
		}

		final filesGenerated:Array<String> = [];
		for (value in (cast files : Array<Dynamic>)) {
			if (!Std.isOfType(value, String)) {
				throw malformed(source, "filesGenerated contains a non-string path");
			}
			filesGenerated.push(checkedRelativePath(cast value, source));
		}
		return {
			version: cast version,
			id: cast id,
			wasCached: cast wasCached,
			filesGenerated: filesGenerated
		};
	}

	public static function encode(metadata:OutputMetadata):String {
		return Json.stringify(metadata, "\t");
	}

	static function checkedRelativePath(path:String, source:String):String {
		if (path.length == 0 || Path.isAbsolute(path)) {
			throw malformed(source, 'filesGenerated contains a non-relative path "$path"');
		}
		final normalized = Path.normalize(path);
		if (normalized.length == 0
			|| normalized == "."
			|| normalized == ".."
			|| StringTools.startsWith(normalized, "../")
			|| StringTools.startsWith(normalized, "..\\")) {
			throw malformed(source, 'filesGenerated contains an escaping path "$path"');
		}
		return normalized;
	}

	static function malformed(source:String, detail:String):haxe.Exception {
		return new haxe.Exception('reflaxe:malformed-output-metadata: Receipt "$source" is invalid: $detail.');
	}
}
#end
