(in-package #:sicl-standard-environment-macros)

;;;; The macros in this file have an important shared property,
;;;; namely, they all access or modify the global environment at
;;;; compile time.  For the extrinsic compiler, this property places
;;;; some restrictions on how these macros can be written in that they
;;;; can not use standard functions for accessing the environment such
;;;; as CL:COMPILER-MACRO or CL:GET-SETF-EXPANSION.  The reason for
;;;; that restriction is that in the extrinsic compiler, code that is
;;;; executed at compile time is executed by the host system, so that
;;;; standard environment-accessing functions access the host
;;;; environment, whereas we want to access the target environment.
;;;;
;;;; Furthermore, we can not use the target version of the standard
;;;; environment-accessing functions, because they would overwrite the
;;;; corresponding host functions.  It would be possible to use
;;;; different packages, but that solution would complicate the code.
;;;;
;;;; The solution we propose is to introduce a protocol for accessing
;;;; the (fist-class) global environment, and the names of the
;;;; functions of that protocol are in a dedicated package that can be
;;;; defined in the host without any risk of clashes.  In the target
;;;; environment, standard environment-accessing functions are defined
;;;; in terms of the protocol functions.  The macros that access the
;;;; environment at compile time use the protocol directly, without
;;;; using the standard functions.  That way, the target versions of
;;;; the standard environment-accessing functions do not have to exist
;;;; in the extrinsic compiler. 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Macro DEFCONSTANT.
;;;
;;; The HyperSpec says that we have a choice as to whether the
;;; initial-value form is evaluated at compile-time, at load-time, or
;;; both, but that in either case, the compiler must recognize the
;;; name as a constant variable.  We have chosen to evaluate it both
;;; at compile-time and at load-time.  We evaluate it at compile time
;;; so that successive references to the variable can be replaced by
;;; the value.
;;;
;;; This is not the final version of the macro.  For one thing, we
;;; need to handle the optional DOCUMENTATION argument.

(defmacro defconstant (name initial-value &optional documentation)
  (declare (ignore documentation))
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf (sicl-env:constant-variable
	    ',name
	    sicl-env:*global-environment*)
	   ,initial-value)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Macro DEFVAR.
;;;
;;; The HyperSpec says that when DEFVAR is processed as a top-level
;;; form, then the rest of the compilation must treat the variable as
;;; special, but the initial-value form must not be evaluated, and
;;; there must be no assignment of any value to the variable.
;;;
;;; This is not the final version of DEFVAR, because we ignore the
;;; documentation for now.

(defmacro defvar
    (name &optional (initial-value nil initial-value-p) documentation)
  (declare (ignore documentation))
  (if initial-value-p
      `(progn
	 (eval-when (:compile-toplevel)
	   (setf (sicl-env:special-variable
		  ',name
		  sicl-env:*global-environment*
		  nil)
		 nil))
	 (eval-when (:load-toplevel :execute)
	   (unless (sicl-env:boundp ',name
				    sicl-env:*global-environment*)
	     (setf (sicl-env:special-variable
		    ',name
		    sicl-env:*global-environment*
		    t)
		   ,initial-value))))
      `(eval-when (:compile-toplevel :load-toplevel :execute)
	 (setf (sicl-env:special-variable
		',name
		sicl-env:*global-environment*
		nil)
	       nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Macro DEFPARAMETER.
;;;
;;; The HyperSpec says that when DEFPARAMETER is processed as a
;;; top-level form, then the rest of the compilation must treat the
;;; variable as special, but the initial-value form must not be
;;; evaluated, and there must be no assignment of any value to the
;;; variable.
;;;
;;; This is not the final version of DEFPARAMETER, because we ignore
;;; the documentation for now.

(defmacro defparameter (name initial-value &optional documentation)
  (declare (ignore documentation))
  `(progn
     (eval-when (:compile-toplevel)
       (setf (sicl-env:special-variable
	      ',name
	      sicl-env:*global-environment*
	      nil)
	     nil))
     (eval-when (:load-toplevel :execute)
       (setf (sicl-env:special-variable
	      ',name
	      sicl-env:*global-environment*
	      t)
	     ,initial-value))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Macro DEFTYPE.

(defmacro deftype (name lambda-list &body body)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf (sicl-env:type-expander
	    ',name
	    sicl-env:*global-environment*)
	   (function ,(cleavir-code-utilities:parse-deftype 
		       name
		       lambda-list
		       body)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Macro DEFINE-COMPILER-MACRO.

(defmacro define-compiler-macro (name lambda-list &body body)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf (sicl-env:compiler-macro-function
	    ',name
	    sicl-env:*global-environment*)
	   (function ,(cleavir-code-utilities:parse-macro
		       name
		       lambda-list
		       body)))))
