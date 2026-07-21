#if macro
import haxe.macro.Context;
#end

/** Adds unrelated macro locals for the focused program-fingerprint regression. **/
class ProgramRevisionPerturbation {
	#if macro
	/** Loads the retained subject after optionally typing unrelated macro locals. **/
	public static function run():Void {
		Context.onAfterInitMacros(() -> {
			if (!Context.defined("reflaxe_program_revision_probe"))
				return;
			if (Context.defined("reflaxe_perturb_program_local_ids")) {
				Context.typeExpr(macro {
					var unrelatedFirst = 1;
					unrelatedFirst + 1;
				});
				Context.typeExpr(macro {
					var unrelatedSecond = 2;
					unrelatedSecond + 1;
				});
			}
			Context.getType("ProgramRevisionSubject");
		});
	}
	#end
}
