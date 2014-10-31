(cl:in-package #:common-lisp-user)

(asdf:defsystem :cleavir-hir-transformations
  :depends-on (:cleavir-mir)
  :serial t
  :components
  ((:file "packages")
   (:file "eliminate-typeq")
   (:file "segregate-lexicals")))
