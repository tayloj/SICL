(cl:in-package #:common-lisp-user)

(asdf:defsystem :cleavir-generate-ast-test
  :depends-on (:cleavir-generate-ast
	       :cleavir-ast-interpreter)
  :serial t
  :components
  ((:file "packages")
   (:file "environment")
   (:file "minimal-compilation")
   (:file "generate-ast")))

