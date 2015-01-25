(cl:in-package #:sicl-environment)

(defun (setf symbol-function) (new-definition symbol environment)
  (assert (not (null environment)))
  (let ((global-env (cleavir-env:global-environment environment)))
    (setf (sicl-global-environment:fdefinition symbol global-env)
	  new-definition)))
