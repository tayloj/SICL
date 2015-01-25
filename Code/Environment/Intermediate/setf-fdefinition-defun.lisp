(cl:in-package #:sicl-environment)

(defun (setf fdefinition) (new-definition function-name environment)
  (assert (not (null environment)))
  (let ((global-env (cleavir-env:global-environment environment)))
    (setf (sicl-global-environment:fdefinition function-name global-env)
	  new-definition)))
