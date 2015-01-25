(defpackage #:hostile-environment
  (:use #:common-lisp)
  (:export))

(in-package #:hostile-environment)

(defclass bogus-environment () ())

(defmethod cleavir-env:variable-info ((environment bogus-environment) symbol)
  (cond (;; We can check whether this symbol names a constant variable
	 ;; by checking the return value of CONSTANTP. 
	 (constantp symbol)
	 ;; If it is a constant variable, we can get its value by
	 ;; calling SYMBOL-VALUE on it.
	 (make-instance 'cleavir-env:constant-variable-info
	   :name symbol
	   :value (symbol-value symbol)))
	(;; If it is not a constant variable, we can check whether
	 ;; macroexpanding it alters it.
	 (not (eq symbol (macroexpand-1 symbol)))
	 ;; Clearly, the symbol is defined as a symbol macro.
	 (make-instance 'cleavir-env:symbol-macro-info
	   :name symbol
	   :expansion (macroexpand-1 symbol)))
	(;; If it is neither a constant variable nor a symbol macro,
	 ;; it might be a special variable.  We can start by checking
	 ;; whether it is bound.
	 (boundp symbol)
	 ;; It may or may not be special.  It is not special if it has
	 ;; not been proclaimed as such but it has been set using
	 ;; (SETF SYMBOL-VALUE).  We have no way of checking that, so
	 ;; we assume that it has been proclaimed special, since that
	 ;; is probably the most common case.
	 (make-instance 'cleavir-env:special-variable-info
	   :name symbol
	   :global-p t)
	(;; If it is not bound, it could still be special.  If so, it
	 ;; might have a restricted type on it.  It will then likely
	 ;; fail to bind it to an object of some type that we
	 ;; introduced, say our bogus environment.  It is not fool
	 ;; proof because it could have the type STANDARD-OBJECT.  But
	 ;; in the worst case, we will just fail to recognize it as a
	 ;; special variable.
	 (null (ignore-errors
		(eval `(let ((,symbol (make-instance 'bogus-environment)))
			 t))))
	 ;; It is a special variable.  However, we don't know its
	 ;; type, so we assume it is T, which is the default.
	 (make-instance 'cleavir-env:special-variable-info
	   :name symbol
	   :global-p t))
	(;; If the previous test fails, it could still be special
	 ;; without any type restriction on it.  We can try to
	 ;; determine whether this is the case by checking whether the
	 ;; ordinary binding (using LET) of it is the same as the
	 ;; dynamic binding of it.  This method might fail because the
	 ;; type of the variable may be restricted to something we
	 ;; don't know and that we didn't catch before, 
	 (ignore-errors
	  (eval `(let ((,symbol 'a))
		   (progv '(,symbol) '(b) (eq ,symbol (symbol-value ',symbol))))))
	 ;; It is a special variable.  However, we don't know its
	 ;; type, so we assume it is T, which is the default.
	 (make-instance 'cleavir-env:special-variable-info
	   :name symbol
	   :global-p t))
	(;; Otherwise, this symbol does not have any variable
	 ;; information associated with it.
	 t
	 ;; Return NIL as the protocol stipulates.
	 nil)))
	 
(defmethod cleavir-env:function-info ((environment bogus-environment) function-name)
  (cond (;; If the function name is the name of a macro, then
	 ;; MACRO-FUNCTION returns something other than NIL.
	 (and (symbolp function-name) (not (null (macro-function function-name))))
	 ;; If so, we know it is a global macro.  It is also safe to
	 ;; call COMPILER-MACRO-FUNCTION, because it returns NIL if
	 ;; there is no compiler macro associated with this function
	 ;; name.
	 (make-instance 'cleavir-env:global-macro-info
	   :name function-name
	   :expander (macro-function function-name)
	   :compiler-macro (compiler-macro-function function-name)))
	(;; If it is not the name of a macro, it might be the name of
	 ;; a special operator.  This can be checked by calling
	 ;; special-operator-p.
	 (and (symbolp function-name) (special-operator-p function-name))
	 (make-instance 'cleavir-env:special-operator-info
	   :name function-name))
	(;; If it is neither the name of a macro nor the name of a
	 ;; special operator, it might be the name of a global
	 ;; function.  We can check this by calling FBOUNDP.  Now,
	 ;; FBOUNDP returns true if it is the name of a macro or a
	 ;; special operator as well, but we have already checked for
	 ;; those cases.
	 (fboundp function-name)
	 ;; In that case, we return the relevant info
	 (make-instance 'cleavir-env:global-function-info
	   :name function-name
	   :compiler-macro (compiler-macro-function function-name)))
	(;; If it is neither of the cases above, then this name does
	 ;; not have any function-info associated with it.
	 t
	 ;; Return NIL as the protocol stipulates.
	 nil)))

(defmethod cleavir-env:optimize-info ((environment bogus-environment))
  ;; The default values are all 3.
  (make-instance 'cleavir-env:optimize-info))
