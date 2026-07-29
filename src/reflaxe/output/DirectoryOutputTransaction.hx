package reflaxe.output;

#if (macro || reflaxe_runtime)
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef DirectoryOutputTransactionMarker = {
	final publicDirectory:String;
	final state:String;
}

/**
	Publishes one complete generated directory without exposing partial output.

	The transaction writes into a private sibling directory on the same
	filesystem. After the compiler and target finish successfully, `commit`
	renames the previous public tree into an owned backup, renames the complete
	candidate into place, and removes the backup. A handled publication failure
	restores the prior tree before it returns an error.

	The fixed private root also records enough state to finish a successful
	cleanup or restore a public directory that was moved immediately before a
	process interruption. Ambiguous or unowned state fails closed instead of
	deleting a path the framework cannot prove it owns.
**/
class DirectoryOutputTransaction {
	public static inline final MARKER_FILENAME = "transaction.marker";
	public static inline final MARKER_FORMAT = "reflaxe-output-transaction-v1";
	public static inline final STATE_PREPARING = "preparing";
	public static inline final STATE_PUBLIC_MOVE_PENDING = "public-move-pending";
	public static inline final STATE_PUBLIC_MOVED = "public-moved";
	public static inline final STATE_CANDIDATE_PUBLISHED = "candidate-published";

	#if reflaxe_lifecycle_test
	public static inline final TEST_BEFORE_INITIAL_MARKER = "before-initial-marker";
	public static inline final TEST_BEFORE_PUBLIC_MOVE = "before-public-move";
	public static inline final TEST_AFTER_PUBLIC_MOVE = "after-public-move";
	public static inline final TEST_AFTER_CANDIDATE_PUBLISH = "after-candidate-publish";
	public static inline final TEST_BEFORE_CLEANUP = "before-cleanup";
	public static inline final TEST_AFTER_BACKUP_CLEANUP = "after-backup-cleanup";
	#end

	public final publicDirectory:String;
	public final candidateDirectory:String;

	final transactionRoot:String;
	final candidateParent:String;
	final backupDirectory:String;
	final backupParent:String;
	final markerPath:String;

	var active = false;
	#if reflaxe_lifecycle_test
	var testFailureStage:Null<String>;
	#end

	public function new(publicDirectory:String) {
		final absolute = Path.normalize(FileSystem.absolutePath(publicDirectory));
		final name = Path.withoutDirectory(absolute);
		final parent = Path.directory(absolute);
		if (name.length == 0 || parent == absolute || absolute.indexOf("\n") != -1 || absolute.indexOf("\r") != -1) {
			throw error("reflaxe:invalid-output-transaction-path",
				'Directory output transactions require a named directory below a parent: "$publicDirectory".');
		}

		this.publicDirectory = absolute;
		transactionRoot = Path.join([parent, '.$name.reflaxe-output-transaction']);
		candidateParent = Path.join([transactionRoot, "candidate"]);
		candidateDirectory = Path.join([candidateParent, name]);
		backupParent = Path.join([transactionRoot, "backup"]);
		backupDirectory = Path.join([backupParent, name]);
		markerPath = Path.join([transactionRoot, MARKER_FILENAME]);
	}

	/**
		Creates and returns the empty private directory for the next candidate.
	**/
	public function begin():String {
		if (active) {
			throw error("reflaxe:duplicate-output-transaction", 'Output directory "$publicDirectory" already has an active transaction.');
		}
		recoverInterruptedPublication();
		if (FileSystem.exists(transactionRoot)) {
			throw error("reflaxe:conflicting-output-transaction", 'Owned transaction path "$transactionRoot" still exists after recovery.');
		}

		try {
			ensureDirectory(candidateDirectory);
			testCheckpoint(#if reflaxe_lifecycle_test TEST_BEFORE_INITIAL_MARKER #else "" #end);
			writeMarker(STATE_PREPARING);
			active = true;
			return candidateDirectory;
		} catch (cause:Dynamic) {
			var cleanupFailure:Null<String> = null;
			try {
				if (FileSystem.exists(transactionRoot))
					deleteTree(transactionRoot);
			} catch (cleanupCause:Dynamic) {
				cleanupFailure = Std.string(cleanupCause);
			}
			if (cleanupFailure != null) {
				throw error("reflaxe:output-transaction-initialization-cleanup-failed",
					'Starting private output for "$publicDirectory" failed (${Std.string(cause)}), and removing the incomplete transaction state also failed ($cleanupFailure). ' +
					'The owned transaction root is "$transactionRoot".');
			}
			throw error("reflaxe:output-transaction-initialization-failed",
				'Starting private output for "$publicDirectory" failed and its incomplete private state was removed: ${Std.string(cause)}');
		}
	}

	/**
		Publishes the validated candidate and removes the prior public tree.

		The candidate and public paths are siblings, so both directory renames
		stay on the same filesystem. If any handled step fails after the old tree
		moves, rollback restores it before the error escapes.
	**/
	public function commit():Void {
		requireActive();
		if (!FileSystem.exists(candidateDirectory) || !FileSystem.isDirectory(candidateDirectory)) {
			throw error("reflaxe:missing-output-transaction-candidate", 'Output transaction candidate "$candidateDirectory" is missing.');
		}

		var publicMoved = false;
		var candidatePublished = false;
		try {
			testCheckpoint(#if reflaxe_lifecycle_test TEST_BEFORE_PUBLIC_MOVE #else "" #end);
			writeMarker(STATE_PUBLIC_MOVE_PENDING);
			if (FileSystem.exists(publicDirectory)) {
				if (!FileSystem.isDirectory(publicDirectory)) {
					throw error("reflaxe:output-transaction-public-not-directory", 'Output transaction path "$publicDirectory" is not a directory.');
				}
				ensureDirectory(backupParent);
				FileSystem.rename(publicDirectory, backupDirectory);
				publicMoved = true;
			}
			writeMarker(STATE_PUBLIC_MOVED);
			testCheckpoint(#if reflaxe_lifecycle_test TEST_AFTER_PUBLIC_MOVE #else "" #end);

			FileSystem.rename(candidateDirectory, publicDirectory);
			candidatePublished = true;
			writeMarker(STATE_CANDIDATE_PUBLISHED);
			testCheckpoint(#if reflaxe_lifecycle_test TEST_AFTER_CANDIDATE_PUBLISH #else "" #end);
			testCheckpoint(#if reflaxe_lifecycle_test TEST_BEFORE_CLEANUP #else "" #end);
		} catch (cause:Dynamic) {
			final rollbackFailure = rollback(publicMoved, candidatePublished);
			if (rollbackFailure != null) {
				throw error("reflaxe:output-transaction-rollback-failed",
					'Publishing "$publicDirectory" failed (${Std.string(cause)}), and restoring the prior output also failed ($rollbackFailure). ' +
					'The owned transaction root is "$transactionRoot".');
			}
			throw error("reflaxe:output-transaction-publication-failed",
				'Publishing "$publicDirectory" failed and the prior output was restored: ${Std.string(cause)}');
		}
		active = false;
		cleanupPublishedState(publicMoved);
	}

	/**
		Discards an uncommitted candidate while leaving public output untouched.
	**/
	public function abort():Void {
		if (!active)
			return;
		if (FileSystem.exists(backupDirectory) || readMarker().state != STATE_PREPARING) {
			throw error("reflaxe:unsafe-output-transaction-abort",
				'Output transaction "$transactionRoot" reached publication state; use rollback recovery instead of deleting it.');
		}
		if (FileSystem.exists(transactionRoot))
			deleteTree(transactionRoot);
		active = false;
	}

	#if reflaxe_lifecycle_test
	/** Selects one deterministic publication checkpoint that should fail. **/
	public function failAtForTest(stage:String):Void {
		testFailureStage = stage;
	}
	#end

	function rollback(publicMoved:Bool, candidatePublished:Bool):Null<String> {
		try {
			if (candidatePublished && FileSystem.exists(publicDirectory))
				deleteTree(publicDirectory);
			if (publicMoved && FileSystem.exists(backupDirectory))
				FileSystem.rename(backupDirectory, publicDirectory);
			if (FileSystem.exists(transactionRoot))
				deleteTree(transactionRoot);
			active = false;
			return null;
		} catch (rollbackCause:Dynamic) {
			return Std.string(rollbackCause);
		}
	}

	/**
		Best-effort cleanup after the new public tree reaches its commit point.

		Once the candidate is public and the marker records that fact, deleting
		the old backup is irreversible. A later cleanup error must therefore
		leave the new tree committed instead of entering a rollback path that can
		no longer restore the old tree. Any surviving marker remains in the
		`candidate-published` state so the next request can finish cleanup.
	**/
	function cleanupPublishedState(publicMoved:Bool):Void {
		try {
			if (publicMoved && FileSystem.exists(backupDirectory))
				deleteTree(backupDirectory);
			testCheckpoint(#if reflaxe_lifecycle_test TEST_AFTER_BACKUP_CLEANUP #else "" #end);
			if (FileSystem.exists(transactionRoot))
				deleteTree(transactionRoot);
		} catch (_) {
			// Publication already committed. Recovery owns any private state
			// that could not be removed during this request.
		}
	}

	function recoverInterruptedPublication():Void {
		if (!FileSystem.exists(transactionRoot))
			return;
		if (!FileSystem.isDirectory(transactionRoot) || !FileSystem.exists(markerPath)) {
			throw error("reflaxe:unowned-output-transaction-state", 'Path "$transactionRoot" exists without a readable Reflaxe transaction marker.');
		}

		final marker = readMarker();
		switch (marker.state) {
			case STATE_PUBLIC_MOVE_PENDING:
				if (FileSystem.exists(candidateDirectory)) {
					final publicExists = FileSystem.exists(publicDirectory);
					final backupExists = FileSystem.exists(backupDirectory);
					if (!publicExists && backupExists) {
						FileSystem.rename(backupDirectory, publicDirectory);
						deleteTree(transactionRoot);
						return;
					}
					if (!backupExists) {
						deleteTree(transactionRoot);
						return;
					}
				}
			case STATE_PUBLIC_MOVED:
				if (!FileSystem.exists(publicDirectory) && FileSystem.exists(candidateDirectory)) {
					if (FileSystem.exists(backupDirectory))
						FileSystem.rename(backupDirectory, publicDirectory);
					deleteTree(transactionRoot);
					return;
				}
				if (FileSystem.exists(publicDirectory) && !FileSystem.exists(candidateDirectory)) {
					deleteTree(publicDirectory);
					if (FileSystem.exists(backupDirectory))
						FileSystem.rename(backupDirectory, publicDirectory);
					deleteTree(transactionRoot);
					return;
				}
			case STATE_CANDIDATE_PUBLISHED:
				if (FileSystem.exists(publicDirectory)
					&& FileSystem.isDirectory(publicDirectory)
					&& !FileSystem.exists(candidateDirectory)) {
					if (FileSystem.exists(backupDirectory))
						deleteTree(backupDirectory);
					deleteTree(transactionRoot);
					return;
				}
			case STATE_PREPARING:
				if (FileSystem.exists(candidateDirectory) && !FileSystem.exists(backupDirectory)) {
					deleteTree(transactionRoot);
					return;
				}
			case _:
		}

		throw error("reflaxe:conflicting-output-transaction",
			'Output directory "$publicDirectory" has interrupted transaction state "${marker.state}" that cannot be recovered automatically.');
	}

	function readMarker():DirectoryOutputTransactionMarker {
		final lines = try {
			File.getContent(markerPath).split("\n");
		} catch (cause:Dynamic) {
			throw error("reflaxe:malformed-output-transaction-marker", 'Cannot read owned transaction marker "$markerPath": ${Std.string(cause)}');
		}
		if (lines.length != 3 || lines[0] != MARKER_FORMAT || lines[1].length == 0 || lines[2].length == 0) {
			throw error("reflaxe:malformed-output-transaction-marker",
				'Owned transaction marker "$markerPath" does not use the expected three-line Reflaxe transaction format.');
		}
		final marker:DirectoryOutputTransactionMarker = {
			state: lines[1],
			publicDirectory: lines[2]
		};
		if (Path.normalize(marker.publicDirectory) != publicDirectory) {
			throw error("reflaxe:foreign-output-transaction-marker", 'Transaction marker "$markerPath" does not own output directory "$publicDirectory".');
		}
		return marker;
	}

	function writeMarker(state:String):Void {
		ensureDirectory(transactionRoot);
		File.saveContent(markerPath, [MARKER_FORMAT, state, publicDirectory].join("\n"));
	}

	function requireActive():Void {
		if (!active) {
			throw error("reflaxe:missing-output-transaction", 'Output directory "$publicDirectory" has no active transaction.');
		}
	}

	function testCheckpoint(stage:String):Void {
		#if reflaxe_lifecycle_test
		if (testFailureStage == stage)
			throw 'Injected output transaction failure at "$stage".';
		#end
	}

	static function ensureDirectory(path:String):Void {
		if (FileSystem.exists(path)) {
			if (!FileSystem.isDirectory(path))
				throw error("reflaxe:output-transaction-path-not-directory", 'Required directory "$path" is a file.');
			return;
		}
		final parent = Path.directory(path);
		if (parent != path && parent.length > 0)
			ensureDirectory(parent);
		FileSystem.createDirectory(path);
	}

	static function deleteTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		// Try unlink first so a directory symlink is removed as a link instead of
		// recursively following its target.
		try {
			FileSystem.deleteFile(path);
			return;
		} catch (_) {}
		if (!FileSystem.isDirectory(path))
			throw error("reflaxe:output-transaction-delete-failed", 'Cannot remove owned transaction path "$path".');
		for (entry in FileSystem.readDirectory(path))
			deleteTree(Path.join([path, entry]));
		FileSystem.deleteDirectory(path);
	}

	static function error(code:String, detail:String):haxe.Exception {
		return new haxe.Exception('$code: $detail');
	}
}
#end
