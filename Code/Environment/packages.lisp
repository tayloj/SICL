(cl:in-package #:common-lisp-user)

(defpackage #:sicl-global-environment
  (:nicknames #:sicl-env)
  (:use #:common-lisp)
  ;; When this package is defined in a host implementation for the
  ;; purpose of cross compilation, we shadow the symbols of the
  ;; COMMON-LISP package that name functions and variables that have
  ;; to do with manipulating the environment.
  (:shadow #:fboundp
	   #:fdefinition
	   #:macro-function
	   #:compiler-macro-function
	   #:boundp
	   #:makunbound
	   #:fmakunbound
	   #:find-class
	   #:find-package
	   #:get-setf-expansion
	   )
  (:export
   #:environment
   #:fboundp
   #:fdefinition
   #:macro-function
   #:compiler-macro-function
   #:function-type
   #:function-inline
   #:function-cell
   #:function-unbound
   #:function-hir
   #:constant-variable
   #:special-variable
   #:symbol-macro
   #:variable-type
   #:setf-expander
   #:default-setf-expander
   #:type-expander
   #:boundp
   #:makunbound
   #:fmakunbound
   #:variable-cell
   #:variable-unbound
   #:find-class
   #:packages
   #:find-package
   #:special-operator
   #:get-setf-expansion
   #:*global-environment*
   ))

(defpackage #:sicl-standard-environment-functions
  (:shadow #:variable)
  (:use #:common-lisp))

(defpackage #:sicl-standard-environment-macros
  (:use #:common-lisp))
