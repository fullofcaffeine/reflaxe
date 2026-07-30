/**
	A source declaration that deliberately uses the same metadata names as
	Haxe's dead-code elimination pass.

	The lifecycle test proves that these source annotations remain part of the
	target input and its fingerprint. The compiler's separate empty,
	position-shaped bookkeeping markers are also retained, but their mutual
	order is normalized because Haxe reads them as presence flags. Source-written
	annotations keep their original content and slots.
**/
@:used
@:directlyUsed
class CompilerReachabilityMetadata {}
