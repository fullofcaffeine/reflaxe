/**
	Provides two compiler declarations with the same source span.

	Haxe represents this abstract and its generated implementation class as
	separate target declarations even though both come from this one source
	declaration. The lifecycle regression uses them to prove that host callback
	order cannot decide target order when source positions are identical.
**/
abstract SameSpanOrder(Int) {}
