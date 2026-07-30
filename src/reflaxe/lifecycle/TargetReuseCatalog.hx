package reflaxe.lifecycle;

#if (macro || reflaxe_runtime)
import haxe.crypto.Sha256;
import haxe.io.Bytes;

/**
	One redacted observation of the reusable macro-interpreter realm.

	The realm identity is process-local evidence, not a semantic cache key.
	A new or replaced macro interpreter creates a different identity and therefore
	turns every attempted reuse into an ordinary miss.
**/
typedef TargetReuseCatalogRealmObservation = {
	final identityRevision:String;
	final requestSequence:Int;
	final survivedPriorRequest:Bool;
	final resetGeneration:Int;
	final lastResetCause:String;
}

/** One stable miss counter suitable for deterministic reports. **/
typedef TargetReuseCatalogMissCount = {
	final reason:String;
	final count:Int;
}

/** Redacted catalog counters and bounded-memory ownership. **/
typedef TargetReuseCatalogStats = {
	final realmIdentityRevision:String;
	final requestSequence:Int;
	final resetGeneration:Int;
	final lastResetCause:String;
	final totalBudgetBytes:Int;
	final maximumEntryBytes:Int;
	final entryCount:Int;
	final payloadBytes:Int;
	final estimatedOverheadBytes:Int;
	final activeLeases:Int;
	final hits:Int;
	final misses:Array<TargetReuseCatalogMissCount>;
	final ineligibleRequests:Int;
	final admissions:Int;
	final rejectedAdmissions:Int;
	final evictions:Int;
	final quarantines:Int;
}

/** Result of attempting to publish one immutable payload. **/
typedef TargetReuseCatalogAdmission = {
	final admitted:Bool;
	final unchanged:Bool;
	final reason:String;
	final payloadRevision:String;
}

/**
	A read lease pins one immutable entry until `close()` is called.

	Callers receive a fresh byte copy rather than the catalog's mutable `Bytes`
	instance. Closing is idempotent. An expired or quarantined lease fails closed.
**/
class TargetReuseCatalogLease {
	final owner:TargetReuseCatalog;
	final entry:TargetReuseCatalogEntry;
	var closed:Bool = false;

	@:allow(reflaxe.lifecycle.TargetReuseCatalog)
	function new(owner:TargetReuseCatalog, entry:TargetReuseCatalogEntry) {
		this.owner = owner;
		this.entry = entry;
	}

	public var namespace(get, never):String;
	public var requestRevision(get, never):String;
	public var payloadRevision(get, never):String;
	public var payloadBytes(get, never):Int;
	public var estimatedOverheadBytes(get, never):Int;

	function get_namespace():String
		return entry.namespace;

	function get_requestRevision():String
		return entry.requestRevision;

	function get_payloadRevision():String
		return entry.payloadRevision;

	function get_payloadBytes():Int
		return entry.payload.length;

	function get_estimatedOverheadBytes():Int
		return entry.estimatedOverheadBytes;

	/** Returns a caller-owned copy of the opaque payload. **/
	public function copyPayload():Bytes {
		if (closed || entry.quarantined)
			throw "Target reuse catalog lease is closed or quarantined.";
		return TargetReuseCatalog.copyBytes(entry.payload);
	}

	/** Releases the entry for eviction. Safe to call more than once. **/
	public function close():Void {
		if (closed)
			return;
		closed = true;
		owner.release(entry);
	}
}

private class TargetReuseCatalogEntry {
	public final namespace:String;
	public final requestRevision:String;
	public final payloadRevision:String;
	public final payload:Bytes;
	public final estimatedOverheadBytes:Int;
	public var lastAccessSequence:Int;
	public var leaseCount:Int = 0;
	public var quarantined:Bool = false;

	public function new(namespace:String, requestRevision:String, payloadRevision:String, payload:Bytes, estimatedOverheadBytes:Int, lastAccessSequence:Int) {
		this.namespace = namespace;
		this.requestRevision = requestRevision;
		this.payloadRevision = payloadRevision;
		this.payload = payload;
		this.estimatedOverheadBytes = estimatedOverheadBytes;
		this.lastAccessSequence = lastAccessSequence;
	}

	public inline function accountedBytes():Int
		return payload.length + estimatedOverheadBytes;
}

/**
	Bounded process-local storage for opaque immutable target-reuse payloads.

	The shared instance lives only in the cached Haxe macro-interpreter realm.
	Its contents are an optional optimization: realm loss, reset, rejection, or
	eviction changes only whether a future request misses. The class owns no
	compiler behavior, typed objects, output writers, or target policy.
**/
class TargetReuseCatalog {
	public static inline final DEFAULT_TOTAL_BUDGET_BYTES = 128 * 1024 * 1024;
	public static inline final DEFAULT_MAXIMUM_ENTRY_BYTES = 64 * 1024 * 1024;
	public static inline final LOCAL_REALM_IDENTITY = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

	static final sharedCatalog = new TargetReuseCatalog(DEFAULT_TOTAL_BUDGET_BYTES, DEFAULT_MAXIMUM_ENTRY_BYTES);
	static final sharedRealmIdentityRevision = createRealmIdentityRevision();
	static var sharedRequestSequence:Int = 0;
	static var sharedResetGeneration:Int = 0;
	static var sharedLastResetCause:String = "realm-created";

	public final totalBudgetBytes:Int;
	public final maximumEntryBytes:Int;

	final entries:Map<String, TargetReuseCatalogEntry> = [];
	final missCountByReason:Map<String, Int> = [];
	var payloadBytes:Int = 0;
	var estimatedOverheadBytes:Int = 0;
	var accessSequence:Int = 0;
	var activeLeases:Int = 0;
	var hits:Int = 0;
	var ineligibleRequests:Int = 0;
	var admissions:Int = 0;
	var rejectedAdmissions:Int = 0;
	var evictions:Int = 0;
	var quarantines:Int = 0;

	/**
		Creates a bounded catalog.

		Production uses the fixed shared limits. Explicit instances allow focused
		mechanics tests to use small budgets without allocating release-sized data.
	**/
	public function new(totalBudgetBytes:Int, maximumEntryBytes:Int) {
		if (totalBudgetBytes <= 0 || maximumEntryBytes <= 0 || maximumEntryBytes > totalBudgetBytes)
			throw "Target reuse catalog budgets must be positive and the entry cap must not exceed the total cap.";
		this.totalBudgetBytes = totalBudgetBytes;
		this.maximumEntryBytes = maximumEntryBytes;
	}

	/** Marks one shared-realm request and returns its process-local identity. **/
	public static function beginSharedRequest():TargetReuseCatalogRealmObservation {
		sharedRequestSequence += 1;
		return {
			identityRevision: sharedRealmIdentityRevision,
			requestSequence: sharedRequestSequence,
			survivedPriorRequest: sharedRequestSequence > 1,
			resetGeneration: sharedResetGeneration,
			lastResetCause: sharedLastResetCause
		};
	}

	/** Returns the shared catalog capability used by the active macro realm. **/
	public static function shared():TargetReuseCatalog
		return sharedCatalog;

	/** Clears every unleased entry and records an explicit reset generation. **/
	public static function resetShared(cause:String):Void {
		sharedCatalog.resetAll();
		sharedResetGeneration += 1;
		sharedLastResetCause = requireToken(cause, "reset cause");
	}

	/** Returns current redacted counters without changing realm state. **/
	public static function sharedStats():TargetReuseCatalogStats
		return sharedCatalog.snapshotStats(sharedRealmIdentityRevision, sharedRequestSequence, sharedResetGeneration, sharedLastResetCause);

	/** Records one ineligible request and each stable reason it bypassed lookup. **/
	public function recordIneligible(reasons:Array<String>):Void {
		if (reasons == null || reasons.length == 0)
			throw "Target reuse catalog ineligible request requires at least one reason.";
		ineligibleRequests += 1;
		final unique:Map<String, Bool> = [];
		for (reason in reasons)
			unique.set(requireToken(reason, "ineligibility reason"), true);
		for (reason in unique.keys())
			recordMiss("ineligible:" + reason);
	}

	/** Records a stable miss reason without exposing request data. **/
	public function recordMiss(reason:String):Void {
		final normalized = requireToken(reason, "miss reason");
		missCountByReason.set(normalized, (missCountByReason.get(normalized) ?? 0) + 1);
	}

	/**
		Publishes one copied immutable payload, evicting least-recently-used
		unleased entries when necessary.
	**/
	public function admit(namespace:String, requestRevision:String, payload:Bytes, estimatedEntryOverheadBytes:Int):TargetReuseCatalogAdmission {
		final normalizedNamespace = requireToken(namespace, "namespace");
		final normalizedRequestRevision = normalizeRevision(requestRevision, "request revision");
		if (payload == null)
			throw "Target reuse catalog payload must not be null.";
		if (estimatedEntryOverheadBytes < 0)
			throw "Target reuse catalog estimated overhead must not be negative.";
		final accounted = payload.length + estimatedEntryOverheadBytes;
		final payloadRevision = "sha256:" + Sha256.make(payload).toHex();
		if (accounted > maximumEntryBytes) {
			rejectedAdmissions += 1;
			return {
				admitted: false,
				unchanged: false,
				reason: "entry-budget-exceeded",
				payloadRevision: payloadRevision
			};
		}

		final id = entryId(normalizedNamespace, normalizedRequestRevision);
		final existing = entries.get(id);
		if (existing != null) {
			if (!existing.quarantined
				&& existing.payloadRevision == payloadRevision
				&& existing.payload.length == payload.length
				&& existing.estimatedOverheadBytes == estimatedEntryOverheadBytes) {
				existing.lastAccessSequence = nextAccessSequence();
				return {
					admitted: true,
					unchanged: true,
					reason: "already-admitted",
					payloadRevision: payloadRevision
				};
			}
			quarantineEntry(id, existing);
			rejectedAdmissions += 1;
			return {
				admitted: false,
				unchanged: false,
				reason: "same-key-different-payload",
				payloadRevision: payloadRevision
			};
		}

		if (!evictUntilFits(accounted)) {
			rejectedAdmissions += 1;
			return {
				admitted: false,
				unchanged: false,
				reason: "catalog-budget-exhausted",
				payloadRevision: payloadRevision
			};
		}

		final copied = copyBytes(payload);
		final entry = new TargetReuseCatalogEntry(normalizedNamespace, normalizedRequestRevision, payloadRevision, copied, estimatedEntryOverheadBytes,
			nextAccessSequence());
		entries.set(id, entry);
		payloadBytes += copied.length;
		estimatedOverheadBytes += estimatedEntryOverheadBytes;
		admissions += 1;
		return {
			admitted: true,
			unchanged: false,
			reason: "admitted",
			payloadRevision: payloadRevision
		};
	}

	/** Looks up and pins one exact entry. A missing or quarantined entry is a miss. **/
	public function lookup(namespace:String, requestRevision:String):Null<TargetReuseCatalogLease> {
		final normalizedNamespace = requireToken(namespace, "namespace");
		final normalizedRequestRevision = normalizeRevision(requestRevision, "request revision");
		final entry = entries.get(entryId(normalizedNamespace, normalizedRequestRevision));
		if (entry == null || entry.quarantined) {
			recordMiss(entry == null ? "not-found" : "quarantined");
			return null;
		}
		entry.lastAccessSequence = nextAccessSequence();
		entry.leaseCount += 1;
		activeLeases += 1;
		hits += 1;
		return new TargetReuseCatalogLease(this, entry);
	}

	/** Removes one corrupt entry before any future lookup can observe it. **/
	public function quarantine(namespace:String, requestRevision:String):Bool {
		final id = entryId(requireToken(namespace, "namespace"), normalizeRevision(requestRevision, "request revision"));
		final entry = entries.get(id);
		if (entry == null)
			return false;
		quarantineEntry(id, entry);
		return true;
	}

	/** Clears one namespace. Active leases make reset fail closed. **/
	public function resetNamespace(namespace:String):Void {
		final normalizedNamespace = requireToken(namespace, "namespace");
		final ids = [for (id => entry in entries) if (entry.namespace == normalizedNamespace) id];
		for (id in ids) {
			final entry = entries.get(id);
			if (entry != null && entry.leaseCount > 0)
				throw 'Target reuse catalog namespace "$normalizedNamespace" has active leases.';
		}
		for (id in ids)
			removeEntry(id);
	}

	/** Clears every entry. Active leases make reset fail closed. **/
	public function resetAll():Void {
		if (activeLeases > 0)
			throw "Target reuse catalog cannot reset while leases are active.";
		for (id in [for (id in entries.keys()) id])
			removeEntry(id);
		missCountByReason.clear();
		hits = 0;
		ineligibleRequests = 0;
		admissions = 0;
		rejectedAdmissions = 0;
		evictions = 0;
		quarantines = 0;
	}

	/** Returns deterministic counters for reports and memory gates. **/
	public function snapshotStats(realmIdentityRevision:String = LOCAL_REALM_IDENTITY, requestSequence:Int = 0, resetGeneration:Int = 0,
			lastResetCause:String = "local-catalog"):TargetReuseCatalogStats {
		final misses = [
			for (reason => count in missCountByReason)
				{
					reason: reason,
					count: count
				}
		];
		misses.sort((left, right) -> Reflect.compare(left.reason, right.reason));
		return {
			realmIdentityRevision: realmIdentityRevision,
			requestSequence: requestSequence,
			resetGeneration: resetGeneration,
			lastResetCause: lastResetCause,
			totalBudgetBytes: totalBudgetBytes,
			maximumEntryBytes: maximumEntryBytes,
			entryCount: countEntries(),
			payloadBytes: payloadBytes,
			estimatedOverheadBytes: estimatedOverheadBytes,
			activeLeases: activeLeases,
			hits: hits,
			misses: misses,
			ineligibleRequests: ineligibleRequests,
			admissions: admissions,
			rejectedAdmissions: rejectedAdmissions,
			evictions: evictions,
			quarantines: quarantines
		};
	}

	@:allow(reflaxe.lifecycle.TargetReuseCatalogLease)
	function release(entry:TargetReuseCatalogEntry):Void {
		if (entry.leaseCount <= 0 || activeLeases <= 0)
			throw "Target reuse catalog lease accounting underflow.";
		entry.leaseCount -= 1;
		activeLeases -= 1;
		if (entry.quarantined && entry.leaseCount == 0)
			removeEntry(entryId(entry.namespace, entry.requestRevision));
	}

	function evictUntilFits(additionalBytes:Int):Bool {
		while (payloadBytes + estimatedOverheadBytes + additionalBytes > totalBudgetBytes) {
			var candidateId:Null<String> = null;
			var candidate:Null<TargetReuseCatalogEntry> = null;
			for (id => entry in entries) {
				if (entry.leaseCount > 0)
					continue;
				final replace = candidate == null
					|| entry.lastAccessSequence < candidate.lastAccessSequence
					|| (entry.lastAccessSequence == candidate.lastAccessSequence && Reflect.compare(id, cast candidateId) < 0);
				if (replace) {
					candidateId = id;
					candidate = entry;
				}
			}
			if (candidateId == null)
				return false;
			removeEntry(candidateId);
			evictions += 1;
		}
		return true;
	}

	function quarantineEntry(id:String, entry:TargetReuseCatalogEntry):Void {
		if (!entry.quarantined) {
			entry.quarantined = true;
			quarantines += 1;
		}
		if (entry.leaseCount == 0)
			removeEntry(id);
	}

	function removeEntry(id:String):Void {
		final entry = entries.get(id);
		if (entry == null)
			return;
		if (entry.leaseCount > 0)
			throw "Target reuse catalog cannot remove an entry with an active lease.";
		entries.remove(id);
		payloadBytes -= entry.payload.length;
		estimatedOverheadBytes -= entry.estimatedOverheadBytes;
	}

	inline function nextAccessSequence():Int {
		accessSequence += 1;
		return accessSequence;
	}

	function countEntries():Int {
		var count = 0;
		for (_ in entries)
			count += 1;
		return count;
	}

	static function entryId(namespace:String, requestRevision:String):String
		return namespace + "\n" + requestRevision;

	static function normalizeRevision(value:String, label:String):String {
		final token = requireToken(value, label);
		if (StringTools.startsWith(token, "sha256:")) {
			final digest = token.substr("sha256:".length);
			if (!~/^[0-9a-f]{64}$/.match(digest))
				throw 'Target reuse catalog $label is not a SHA-256 value.';
			return token;
		}
		if (!~/^[0-9a-f]{64}$/.match(token))
			throw 'Target reuse catalog $label is not a SHA-256 value.';
		return "sha256:" + token;
	}

	static function requireToken(value:String, label:String):String {
		final token = value == null ? "" : StringTools.trim(value);
		if (token.length == 0)
			throw 'Target reuse catalog $label must not be empty.';
		return token;
	}

	static function createRealmIdentityRevision():String {
		final entropy = Std.string(haxe.Timer.stamp()) + ":" + Std.string(Std.random(0x3fffffff)) + ":" + Std.string(Date.now().getTime());
		return "sha256:" + Sha256.encode(entropy);
	}

	@:allow(reflaxe.lifecycle.TargetReuseCatalogLease)
	static function copyBytes(source:Bytes):Bytes {
		final copy = Bytes.alloc(source.length);
		copy.blit(0, source, 0, source.length);
		return copy;
	}
}
#end
