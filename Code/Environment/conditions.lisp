(cl:in-package #:sicl-standard-environment-functions)

(define-condition no-such-class (error)
  ((%name :initarg :name :reader name)))

(define-condition variables-must-be-proper-list (program-error)
  ((%variables :initarg :variables :reader variables)))

(define-condition variable-must-be-symbol (program-error)
  ((%variable :initarg :variable :reader variable)))
