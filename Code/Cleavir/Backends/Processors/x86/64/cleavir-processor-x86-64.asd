(cl:in-package #:common-lisp-user)

(asdf:defsystem :cleavir-processor-x86-64
  :depends-on (:cleavir-ir :cleavir-mir :cleavir-lir)
  :serial t
  :components
  ((:file "packages")
   (:file "generic-functions")
   (:file "classes")))
