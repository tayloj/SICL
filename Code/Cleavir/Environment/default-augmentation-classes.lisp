(cl:in-package #:cleavir-environment)

(defclass entry ()
  ((%next :initarg :next :reader next)))

(defclass lexical-variable (entry)
  ((%name :initarg :name :reader name)))

(defmethod add-lexical-variable (environment symbol)
  (make-instance 'lexical-variable
    :next environment
    :name symbol))

(defclass special-variable (entry)
  ((%name :initarg :name :reader name)
   (%global-p :initarg :global-p :reader global-p)))

;;; FIXME: should this function take a global-p argument?
(defmethod add-special-variable (environment symbol)
  (make-instance 'special-variable
    :next environment
    :name symbol))

(defclass symbol-macro (entry)
  ((%name :initarg :name :reader name)
   (%expansion :initarg :expansion :reader expansion)))

(defmethod add-local-symbol-macro (environment symbol expansion)
  (make-instance 'symbol-macro
    :name symbol
    :expansion expansion))

(defclass function (entry)
  ((%name :initarg :name :reader name)
   (%identity :initarg :identity :reader identity)))

(defmethod add-local-function (environment function-name)
  (make-instance 'function
    :name function-name
    :identity (gensym)))

(defclass macro (entry)
  ((%name :initarg :name :reader name)
   (%expander :initarg :expander :reader expander)))

(defmethod add-local-macro (environment symbol expander)
  (make-instance 'macro
    :name symbol
    :expander expander))

(defclass block (entry)
  ((%name :initarg :name :reader name)
   (%identity :initarg :identity :reader identity)))

(defmethod add-block (environment symbol)
  (make-instance 'block
    :name symbol
    :identity (gensym)))

(defclass tag (entry)
  ((%name :initarg :name :reader name)
   (%identity :initarg :identity :reader identity)))

(defmethod add-tag (environment symbol)
  (make-instance 'tag
    :name symbol
    :identity (gensym)))

(defclass variable-type (entry)
  ((%name :initarg :name :reader name)
   (%type :initarg :type :reader type)))

(defmethod add-variable-type (environment symbol type)
  (make-instance 'variable-type
    :name symbol
    :type type))

(defclass function-type (entry)
  ((%name :initarg :name :reader name)
   (%type :initarg :type :reader type)))

(defmethod add-function-type (environment function-name type)
  (make-instance 'function-type
    :name function-name
    :type type))

(defclass variable-ignore (entry)
  ((%name :initarg :name :reader name)
   (%ignore :initarg :ignore :reader ignore)))

(defmethod add-variable-ignore (environment symbol ignore)
  (make-instance 'variable-ignore
    :name symbol
    :ignore ignore))

(defclass function-ignore (entry)
  ((%name :initarg :name :reader name)
   (%ignore :initarg :ignore :reader ignore)))

(defmethod add-function-ignore (environment function-name ignore)
  (make-instance 'function-ignore
    :name function-name
    :ignore ignore))

(defclass variable-dynamic-extent (entry)
  ((%name :initarg :name :reader name)))

(defmethod add-variable-dynamic-extent (environment symbol)
  (make-instance 'variable-dynamic-extent
    :name symbol))

(defclass function-dynamic-extent (entry)
  ((%name :initarg :name :reader name)))

(defmethod add-function-dynamic-extent (environment function-name)
  (make-instance 'function-dynamic-extent
    :name function-name))

(defclass optimize (entry)
  ((%quality :initarg :quality :reader quality)
   (%value :initarg :value :reader value)))

(defmethod add-optimize (environment quality value)
  (make-instance 'optimize
    :quality quality
    :value value))

(defclass inline (entry)
  ((%name :initarg :name :reader name)
   (%inline :initarg :inline :reader inline)))

(defmethod add-inline (environment function-name inline)
  (make-instance 'inline
    :name function-name
    :inline inline))