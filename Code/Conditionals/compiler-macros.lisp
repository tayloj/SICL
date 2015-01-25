;;;; Copyright (c) 2008 - 2013
;;;;
;;;;     Robert Strandh (robert.strandh@gmail.com)
;;;;
;;;; all rights reserved. 
;;;;
;;;; Permission is hereby granted to use this software for any 
;;;; purpose, including using, modifying, and redistributing it.
;;;;
;;;; The software is provided "as-is" with no warranty.  The user of
;;;; this software assumes any responsibility of the consequences. 

;;;; This file is part of the conditionals module of the SICL project.
;;;; See the file SICL.text for a description of the project. 
;;;; See the file conditionals.text for a description of the module.

;;; This implementation also does not use the format function, and
;;; instead uses print and princ for error reporting.  This makes it
;;; possible for format to use the conditional constructs define here.

(in-package #:sicl-conditionals)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; We have a dilemma here.  
;;;
;;; On the one hand, we would like for macros to do as much error
;;; checking as possible on the form to be expanded.  This objective
;;; suggests using a lambda list that will always work, such as
;;; (&whole form &rest args) and then do the error checking on the
;;; form, and the arguments inside the macro function.  In particular,
;;; if we use the entire form to report errors, there is a good chance
;;; that source tracking can figure out where it came from so that
;;; error reporting can show the source location.
;;;
;;; On the other hand, the development environment, in particular
;;; SLIME, might use the lambda list to give the programmer some hints
;;; as to what arguments to supply to the form.  If we use a lambda
;;; list such as (&whole form &rest args) for the macros, then we will
;;; render this tool completely useless, which we don't want.
;;;
;;; The solution is as follows: We use a destructuring lambda list in
;;; order to give the programmer hints through the development
;;; environment.  We then use a compiler macro to do the error
;;; checking.

(define-compiler-macro or (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro and (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro when (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  (cleavir-code-utilities:check-argcount form 1 nil)
  form)

(define-compiler-macro unless (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  (cleavir-code-utilities:check-argcount form 1 nil)
  form)

(define-compiler-macro cond (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro case (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro ecase (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro ccase (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro typecase (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro etypecase (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

(define-compiler-macro ctypecase (&whole form &rest args)
  (declare (ignore args))
  (cleavir-code-utilities:check-form-proper-list form)
  form)

