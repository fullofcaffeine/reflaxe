package reflaxe.preprocessors;

import reflaxe.data.ClassFuncData;

abstract class BasePreprocessor {
	/**
		Returns the stable name used by semantic lifecycle contracts and traces.

		Custom preprocessors may override this when a class has multiple behavior
		versions that require distinct contracts.
	**/
	public function semanticLifecycleId(): String {
		final cls = Type.getClass(this);
		return cls != null ? Type.getClassName(cls) : "anonymous-custom-preprocessor";
	}

	public abstract function process(data: ClassFuncData, compiler: BaseCompiler): Void;
}
