package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.io.BytesOutput;
import haxe.io.Path;
#if macro
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;
#end

/**
	Identifies the exact generic Reflaxe implementation used by one request.

	Generic Reflaxe selects the final typed program, runs shared preprocessing,
	manages generated files, and publishes the output transaction. A change to
	any of that code can change target output even when the target package itself
	is unchanged. The revision therefore hashes every Haxe source file under the
	installed `reflaxe` package directory. A cache entry created by different
	framework code receives a different request key and becomes a safe miss.

	The digest is path-independent: it contains sorted paths relative to the
	package directory and the complete bytes of each file. Target and target
	runtime sources remain separately owned revision domains.
**/
class ReflaxeImplementationRevision {
	public static inline final COMPONENT_NAME = "reflaxe-framework-implementation";
	public static inline final MODEL = "reflaxe-framework-source-tree-v1";

	/** Returns the exact lowercase SHA-256 revision of the installed framework sources. **/
	public static function current():String {
		#if macro
		final anchor = Context.resolvePath("reflaxe/BaseCompiler.hx");
		final root = Path.directory(anchor);
		final paths = new Array<String>();
		collectSourcePaths(root, "", paths);
		paths.sort(Reflect.compare);
		if (paths.length == 0)
			throw "Reflaxe framework implementation source inventory is empty.";

		final encoded = new BytesOutput();
		encoded.bigEndian = true;
		writeString(encoded, MODEL);
		encoded.writeInt32(paths.length);
		for (relative in paths) {
			final bytes = File.getBytes(Path.join([root, relative]));
			writeString(encoded, relative);
			encoded.writeInt32(bytes.length);
			encoded.write(bytes);
		}
		return "sha256:" + Sha256.make(encoded.getBytes()).toHex();
		#else
		throw "The Reflaxe framework implementation revision is available only while Haxe macros are running.";
		#end
	}

	#if macro
	static function collectSourcePaths(root:String, relativeDirectory:String, result:Array<String>):Void {
		final directory = relativeDirectory.length == 0 ? root : Path.join([root, relativeDirectory]);
		final names = FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			final relative = relativeDirectory.length == 0 ? name : relativeDirectory + "/" + name;
			final absolute = Path.join([root, relative]);
			if (FileSystem.isDirectory(absolute)) {
				collectSourcePaths(root, relative, result);
			} else if (StringTools.endsWith(name, ".hx")) {
				result.push(StringTools.replace(relative, "\\", "/"));
			}
		}
	}

	static function writeString(output:BytesOutput, value:String):Void {
		final bytes = haxe.io.Bytes.ofString(value);
		output.writeInt32(bytes.length);
		output.write(bytes);
	}
	#end
}
#end
