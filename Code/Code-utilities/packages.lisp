(in-package #:common-lisp-user)

(defpackage #:sicl-code-utilities
  (:use #:common-lisp
	#:sicl-additional-types
	#:sicl-additional-conditions)
  (:export #:list-structure
	   #:proper-list-p
	   #:proper-list-length
	   #:dotted-list-p
	   #:dotted-list-length
	   #:proper-or-dotted-list-length
	   #:circular-list-p
	   #:lambda-list
	   #:required
	   #:environment
	   #:whole
	   #:optionals
	   #:rest-body
	   #:keys
	   #:allow-other-keys
	   #:aux
	   #:parse-ordinary-lambda-list
	   #:parse-generic-function-lambda-list
	   #:parse-specialized-lambda-list
	   #:parse-macro-lambda-list
	   #:parse-destructuring-lambda-list
	   #:parse-deftype-lambda-list
	   #:parse-defsetf-lambda-list
	   #:parse-define-modify-macro-lambda-list
	   #:parse-define-method-combination-arguments-lambda-list
	   #:destruture-lambda-list
	   #:parse-macro
	   #:lambda-lists-congruent-p
	   #:generate-congruent-lambda-list
	   #:canonicalize-declaration-specifiers
	   #:separate-ordinary-body))

