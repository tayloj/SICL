(in-package #:cleavir-ast)

;;;; We define the abstract syntax trees (ASTs) that represent not
;;;; only Common Lisp code, but also the low-level operations that we
;;;; use to implement the Common Lisp operators that can not be
;;;; portably implemented using other Common Lisp operators.
;;;; 
;;;; The AST is a very close representation of the source code, except
;;;; that the environment is no longer present, so that there are no
;;;; longer any different namespaces for functions and variables.  And
;;;; of course, operations such as MACROLET are not present because
;;;; they only alter the environment.  
;;;;
;;;; The AST form is the preferred representation for some operations;
;;;; in particular for PROCEDURE INTEGRATION (sometimes called
;;;; INLINING).

(defgeneric children (ast))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class AST.  The base class for all AST classes.

(defclass ast () ())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Mixin classes.

;;; This class is used as a superclass for ASTs that produce Boolean
;;; results, so are mainly used as the TEST-AST of an IF-AST.
(defclass boolean-ast-mixin () ())

;;; This class is used as a superclass for ASTs that produce no value
;;; and that must be compiled in a context where no value is required.
(defclass no-value-ast-mixin () ())

;;; This class is used as a superclass for ASTs that produce a single
;;; value that is not typically not just a Boolean value.
(defclass one-value-ast-mixin () ())

;;; This class is used as a superclass for ASTs that have no side
;;; effect.
(defclass side-effect-free-ast-mixin () ())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Predicate to test whether an AST is side-effect free.
;;;
;;; For instances of SIDE-EFFECT-FREE-AST-MIXIN, this predicate always
;;; returns true.  For others, it has a default method that returns
;;; false.  Implementations may add a method on some ASTs such as
;;; CALL-AST that return true only if a particular call is side-effect
;;; free.

(defgeneric side-effect-free-p (ast))

(defmethod side-effect-free-p (ast)
  (declare (ignore ast))
  nil)

(defmethod side-effect-free-p ((ast side-effect-free-ast-mixin))
  (declare (ignorable ast))
  t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; AST classes for standard common lisp features. 
;;;
;;; There is mostly a different type of AST for each Common Lisp
;;; special operator, but there are some exceptions.  Here are the
;;; Common Lisp special operators: BLOCK, CATCH, EVAL-WHEN, FLET,
;;; FUNCTION, GO, IF, LABELS, LET, LET*, LOAD-TIME-VALUE, LOCALLY,
;;; MACROLET, MULTIPLE-VALUE-CALL, MULTIPLE-VALUE-PROG1, PROGN, PROGV,
;;; QUOTE, RETURN-FROM, SETQ, SYMBOL-MACROLET, TAGBODY, THE, THROW,
;;; UNWIND-PROTECT.
;;;
;;; Some of these only influence the environment and do not need a
;;; representation as ASTs.  These are: LOCALLY, MACROLET, and
;;; SYMBOL-MACROLET.
;;;
;;; FLET and LABELS are like LET except that the symbols the bind are
;;; in the function namespace, but the distinciton between namespeces
;;; no longer exists in the AST.
;;; 
;;; A LAMBDA expression, either inside (FUNCTION (LAMBDA ...)) or when
;;; it is the CAR of a compound form, compiles into a FUNCTION-AST.
;;; The FUNCTION special form does not otherwise require an AST
;;; because the other form of the FUNCTION special form is just a
;;; conversion between namespaces and again, namespaces are no longer
;;; present in the AST.
;;;
;;; We also define ASTs that do not correspond to any Common Lisp
;;; special operators, because we simplify later code generation that
;;; way.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class CONSTANT-AST. 
;;;
;;; This class represents Lisp constants in source code.  
;;;
;;; If the constant that was found was wrapped in QUOTE, then the
;;; QUOTE is not part of the value here, because it was stripped off.
;;;
;;; If the constant that was found was a constant variable, then the
;;; value here represents the value of that constant variable at
;;; compile time.

(defclass constant-ast (ast one-value-ast-mixin side-effect-free-ast-mixin)
  ((%value :initarg :value :reader value)))

(defun make-constant-ast (value)
  (make-instance 'constant-ast :value value))

(cleavir-io:define-save-info constant-ast
  (:value value))

(defmethod children ((ast constant-ast))
  (declare (ignorable ast))
  '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class LEXICAL-AST.
;;; 
;;; A LEXICAL-AST represents a reference to a lexical variable.  Such
;;; a reference contains the name of the variable, but it is used only
;;; for debugging purposes and for the purpose of error reporting.

(defclass lexical-ast (ast one-value-ast-mixin side-effect-free-ast-mixin)
  ((%name :initarg :name :reader name)))

(defun make-lexical-ast (name)
  (make-instance 'lexical-ast :name name))

(cleavir-io:define-save-info lexical-ast
  (:name name))

(defmethod children ((ast lexical-ast))
  (declare (ignorable ast))
  '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class SYMBOL-VALUE-AST.
;;;
;;; This AST is generated from a reference to a special variable.

(defclass symbol-value-ast (ast one-value-ast-mixin side-effect-free-ast-mixin)
  ((%symbol :initarg :symbol :reader symbol)))

(defun make-symbol-value-ast (symbol)
  (make-instance 'symbol-value-ast :symbol symbol))

(cleavir-io:define-save-info symbol-value-ast
  (:symbol symbol))

(defmethod children ((ast symbol-value-ast))
  '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class SET-SYMBOL-VALUE-AST.
;;;
;;; This AST is generated from an assignment to a special variable.

(defclass set-symbol-value-ast (ast no-value-ast-mixin)
  ((%symbol :initarg :symbol :reader symbol)
   (%value-ast :initarg :value-ast :reader value-ast)))

(defun make-set-symbol-value-ast (symbol value-ast)
  (make-instance 'set-symbol-value-ast
    :symbol symbol
    :value-ast value-ast))

(cleavir-io:define-save-info set-symbol-value-ast
  (:symbol symbol)
  (:value-ast value-ast))

(defmethod children ((ast set-symbol-value-ast))
  (list (value-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class FDEFINITION-AST.
;;;
;;; This AST is generated from a reference to a global function.
;;; NAME is not an AST but just a function name. 

(defclass fdefinition-ast (ast one-value-ast-mixin side-effect-free-ast-mixin)
  (;; This slot contains the function name.
   (%name :initarg :name :reader name)
   ;; This slot contains the INFO instance that was returned form
   ;; the environment query.
   (%info :initarg :info :reader info)))

(defun make-fdefinition-ast (name info)
  (make-instance 'fdefinition-ast :name name :info info))

(cleavir-io:define-save-info fdefinition-ast
  (:name name))

(defmethod children ((ast fdefinition-ast))
  '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class CALL-AST. 
;;;
;;; A CALL-AST represents a function call.  

(defclass call-ast (ast)
  ((%callee-ast :initarg :callee-ast :reader callee-ast)
   (%argument-asts :initarg :argument-asts :reader argument-asts)))

(defun make-call-ast (callee-ast argument-asts)
  (make-instance 'call-ast
    :callee-ast callee-ast
    :argument-asts argument-asts))

(cleavir-io:define-save-info call-ast
  (:callee-ast callee-ast)
  (:argument-asts argument-asts))

(defmethod children ((ast call-ast))
  (cons (callee-ast ast) (argument-asts ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class FUNCTION-AST.
;;;
;;; A function AST represents an explicit lambda expression, but also
;;; implicit lambda expressions such as the ones found in FLET and
;;; LABELS.
;;;
;;; The lambda list is not a normal lambda list.  It has the following
;;; form: 
;;; ([r1 .. rl [&optional o1 ..om] [&key k1 .. kn &allow-other-keys]]]) 
;;;
;;; where: 
;;;
;;;   - Each ri is a LEXICAL-AST. 
;;;
;;;   - Each oi is a list of two LEXICAL-ASTs.  The second of the 
;;;     two conceptually contains a Boolean value indicating whether
;;;     the first one contains a value supplied by the caller.  
;;;
;;;   - Each ki is a list of a symbol and two LEXICAL-ASTs.  The
;;;     symbol is the keyword-name that a caller must supply in order
;;;     to pass the corresponding argument.  The second of the two
;;;     LEXICAL-ASTs conceptually contains a Boolean value indicating
;;;     whether the first LEXICAL-AST contains a value supplied by the
;;;     caller.
;;;
;;; The LEXICAL-ASTs in the lambda list are potentially unrelated to
;;; the variables that were given in the original lambda expression,
;;; and they are LEXICAL-ASTs independently of whether the
;;; corresponding variable that was given in the original lambda
;;; expression is a lexical variable or a special variable.
;;;
;;; The body of the FUNCTION-AST must contain code that tests the
;;; second of the two LEXICAL-ASTs and initializes variables if
;;; needed.  The if the second LEXICAL-AST in any oi contains FALSE,
;;; then the code in the body is not allowed to test the second
;;; LEXICAL-ASTs of any of the ki because they may not be set
;;; correctly (conceptually, they all have the value FALSE then).

(defclass function-ast (ast one-value-ast-mixin side-effect-free-ast-mixin)
  ((%lambda-list :initarg :lambda-list :reader lambda-list)
   (%body-ast :initarg :body-ast :reader body-ast)))

(defun make-function-ast (body-ast lambda-list)
  (make-instance 'function-ast
    :body-ast body-ast
    :lambda-list lambda-list))

(cleavir-io:define-save-info function-ast
  (:lambda-list lambda-list)
  (:body-ast body-ast))

(defmethod children ((ast function-ast))
  (list (body-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class PROGN-AST.

(defclass progn-ast (ast)
  ((%form-asts :initarg :form-asts :reader form-asts)))

(defun make-progn-ast (form-asts)
  (make-instance 'progn-ast
    :form-asts form-asts))

(cleavir-io:define-save-info function-ast
  (:form-asts form-asts))

(defmethod children ((ast progn-ast))
  (form-asts ast))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class BLOCK-AST.

(defclass block-ast (ast)
  ((%body-ast :initarg :body-ast :accessor body-ast)))

(defun make-block-ast (body-ast)
  (make-instance 'block-ast
    :body-ast body-ast))
  
(cleavir-io:define-save-info block-ast
  (:body-ast body-ast))

(defmethod children ((ast block-ast))
  (list (body-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class RETURN-FROM-AST.

(defclass return-from-ast (ast)
  ((%block-ast :initarg :block-ast :reader block-ast)
   (%form-ast :initarg :form-ast :reader form-ast)))

(defun make-return-from-ast (block-ast form-ast)
  (make-instance 'return-from-ast
    :block-ast block-ast
    :form-ast form-ast))
  
(cleavir-io:define-save-info return-from-ast
  (:block-ast block-ast)
  (:form-ast form-ast))

(defmethod children ((ast return-from-ast))
  (list (block-ast ast) (form-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class SETQ-AST.
;;; 
;;; This AST does not correspond exactly to the SETQ special operator,
;;; because the AST does not return a value.

(defclass setq-ast (ast no-value-ast-mixin)
  ((%lhs-ast :initarg :lhs-ast :reader lhs-ast)
   (%value-ast :initarg :value-ast :reader value-ast)))

(defun make-setq-ast (lhs-ast value-ast)
  (make-instance 'setq-ast
    :lhs-ast lhs-ast
    :value-ast value-ast))

(cleavir-io:define-save-info setq-ast
  (:lhs-ast lhs-ast)
  (:value-ast value-ast))

(defmethod children ((ast setq-ast))
  (list (lhs-ast ast) (value-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class TAG-AST.

(defclass tag-ast (ast)
  ((%name :initarg :name :reader name)))

(defun make-tag-ast (name)
  (make-instance 'tag-ast
    :name name))

(cleavir-io:define-save-info tag-ast
  (:name name))

(defmethod children ((ast tag-ast))
  (declare (ignorable ast))
  '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class TAGBODY-AST.

(defclass tagbody-ast (ast no-value-ast-mixin)
  ((%item-asts :initarg :item-asts :reader item-asts)))

(defun make-tagbody-ast (item-asts)
  (make-instance 'tagbody-ast
    :item-asts item-asts))

(defmethod children ((ast tagbody-ast))
  (item-asts ast))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class GO-AST.

(defclass go-ast (ast)
  ((%tag-ast :initarg :tag-ast :reader tag-ast)))

(defun make-go-ast (tag-ast)
  (make-instance 'go-ast
    :tag-ast tag-ast))

(cleavir-io:define-save-info go-ast
  (:tag-ast tag-ast))

(defmethod children ((ast go-ast))
  (list (tag-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class THE-AST.
;;;
;;; This AST can be generated by from the THE special operator, but
;;; also implicitly from type declarations and assignments to
;;; variables with type declarations.  
;;;
;;; When the slot CHECK-P is true, code is generated to check that the
;;; type is correct.  When it is false, no code is generated, but the
;;; type inference machinery uses the type to optimize the code. 

(defclass the-ast (ast)
  ((%check-p :initarg :check-p :initform t :reader check-p)
   (%form-ast :initarg :form-ast :reader form-ast)
   (%type-specifiers :initarg :type-specifiers :reader type-specifiers)))

(defun make-the-ast (form-ast type-specifiers)
  (make-instance 'the-ast
    :form-ast form-ast
    :type-specifiers type-specifiers))

(cleavir-io:define-save-info the-ast
  (:check-p check-p)
  (:form-ast form-ast)
  (:type-specifiers type-specifiers))

(defmethod children ((ast the-ast))
  (list (form-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class TYPEQ-AST.
;;;
;;; This AST can be thought of as a translation to an AST of a
;;; hypothetical special form (TYPEQ <form> <type-specifier>) which is
;;; like the function TYPEP, except that the type specifier is not
;;; evaluated.  
;;;
;;; Like a call to the function TYPEP, the value of this AST is a
;;; generalized Boolean that is TRUE if and only if <form> is of type
;;; <type-specifier>.
;;;
;;; Implementations that interpret the special form (THE <type>
;;; <form>) as an error if <form> is not of type <type> might generate
;;; a TYPEQ-AST contained in an IF-AST instead of a THE-AST, and to
;;; have the ELSE branch of the IF-AST call ERROR.
;;;
;;; The TYPEQ-AST can also be used as a target for the standard macro
;;; CHECK-TYPE.  An implementation might for instance expand
;;; CHECK-TYPE to a form containing an implementation-specific special
;;; operator; e.g, (UNLESS (TYPEQ <form> <type-spec>) (CERROR ...))
;;; and then translate the implementation-specific special operator
;;; TYPEQ into a TYPEQ-AST.
;;;
;;; The TYPEQ-AST generates instructions that are used in the static
;;; type inference phase.  If static type inference can determine the
;;; value of the TYPEQ-AST, then no runtime test is required.  If not,
;;; then a call to TYPEP is generated instead. 

(defclass typeq-ast (ast)
  ((%type-specifier :initarg :type-specifier :reader type-specifier)
   (%form-ast :initarg :form-ast :reader form-ast)))

(defun make-typeq-ast (form-ast type-specifier)
  (make-instance 'typeq-ast
    :form-ast form-ast
    :type-specifier type-specifier))

(cleavir-io:define-save-info typeq-ast
  (:type-specifier type-specifier)
  (:form-ast form-ast))

(defmethod children ((ast typeq-ast))
  (list (form-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class LOAD-TIME-VALUE-AST.
;;;
;;; This AST corresponds directly to the LOAD-TIME-VALUE special
;;; operator.  It has a single child and it produces a single value.
;;;
;;; The optional argument READ-ONLY-P is not a child of the AST
;;; because it can only be a Boolean which is not evaluated, so we
;;; know at AST creation time whether it is true or false. 

(defclass load-time-value-ast (ast)
  ((%form-ast :initarg :form-ast :reader form-ast)
   (%read-only-p :initarg :read-only-p :reader read-only-p)))

(defun make-load-time-value-ast (form-ast &optional read-only-p)
  (make-instance 'load-time-value-ast
    :form-ast form-ast
    :read-only-p read-only-p))

;;; Even though READ-ONLY-P is not a child of the AST, it needs to be
;;; saved when the AST is saved. 
(cleavir-io:define-save-info load-time-value-ast
  (:read-only-p read-only-p))

(defmethod children ((ast load-time-value-ast))
  (list (form-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class IF-AST.
;;;
;;; This AST corresponds directly to the IF special operator.  It
;;; produces as many values as the AST in the THEN-AST or ELSE-AST
;;; produces, according to the value of the TEST AST.

(defclass if-ast (ast)
  ((%test-ast :initarg :test-ast :reader test-ast)
   (%then-ast :initarg :then-ast :reader then-ast)
   (%else-ast :initarg :else-ast :reader else-ast)))

(defun make-if-ast (test-ast then-ast else-ast)
  (make-instance 'if-ast
    :test-ast test-ast
    :then-ast then-ast
    :else-ast else-ast))

(cleavir-io:define-save-info if-ast
  (:test-ast test-ast)
  (:then-ast then-ast)
  (:else-ast else-ast))

(defmethod children ((ast if-ast))
  (list (test-ast ast) (then-ast ast) (else-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class MULTIPLE-VALUE-CALL-AST.

(defclass multiple-value-call-ast (ast)
  ((%function-form-ast :initarg :function-form-ast :reader function-form-ast)
   (%form-asts :initarg :form-asts :reader form-asts)))

(defun make-multiple-value-call-ast (function-form-ast form-asts)
  (make-instance 'multiple-value-call-ast
    :function-form-ast function-form-ast
    :form-asts form-asts))

(cleavir-io:define-save-info multiple-value-call-ast
  (:function-form-ast function-form-ast)
  (:form-asts form-asts))

(defmethod children ((ast multiple-value-call-ast))
  (cons (function-form-ast ast)
	(form-asts ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class MULTIPLE-VALUE-PROG1-AST.

(defclass multiple-value-prog1-ast (ast)
  ((%first-form-ast :initarg :first-form-ast :reader first-form-ast)
   ;; A list of ASTs
   (%form-asts :initarg :form-asts :reader form-asts)))

(defun make-multiple-value-prog1-ast (first-form-ast form-asts)
  (make-instance 'multiple-value-prog1-ast
    :first-form-ast first-form-ast
    :form-asts form-asts))

(cleavir-io:define-save-info multiple-value-prog1-ast
  (:first-form-ast first-form-ast)
  (:form-asts form-asts))

(defmethod children ((ast multiple-value-prog1-ast))
  (cons (first-form-ast ast)
	(form-asts ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class BIND-AST.
;;;
;;; This AST is used to create a dynamic binding for a symbol for the
;;; duration of the execution of the body.  It is generated as a
;;; result of a binding of a special variable in a LET, LET*, or a
;;; lambda list of a function. 

(defclass bind-ast (ast)
  ((%symbol :initarg :symbol :reader symbol)
   (%value-ast :initarg :value-ast :reader value-ast)
   (%body-ast :initarg :body-ast :reader body-ast)))

(defun make-bind-ast (symbol value-ast body-ast)
  (make-instance 'bind-ast
    :symbol symbol
    :value-ast value-ast
    :body-ast body-ast))

(cleavir-io:define-save-info bind-ast
  (:symbol symbol)
  (:value-ast value-ast)
  (:body-ast body-ast))

(defmethod children ((ast bind-ast))
  (list (value-ast ast) (body-ast ast)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class EQ-AST.
;;;
;;; This AST can be used to to test whether two objects are identical.
;;; It has two children.  This AST can only appear in the TEST
;;; position of an IF-AST.

(defclass eq-ast (ast)
  ((%arg1-ast :initarg :arg1-ast :reader arg1-ast)
   (%arg2-ast :initarg :arg2-ast :reader arg2-ast)))

(defun make-eq-ast (arg1-ast arg2-ast)
  (make-instance 'eq-ast
    :arg1-ast arg1-ast
    :arg2-ast arg2-ast))

(cleavir-io:define-save-info eq-ast
  (:arg1-ast arg1-ast)
  (:arg2-ast arg2-ast))

(defmethod children ((ast eq-ast))
  (list (arg1-ast ast) (arg2-ast ast)))

