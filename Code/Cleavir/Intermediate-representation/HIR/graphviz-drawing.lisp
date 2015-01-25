(in-package #:cleavir-ir-graphviz)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing a datum on a stream.

(defgeneric draw-datum (datum stream))

;;; During the drawing process, the value of this variable is a hash
;;; table that contains data that have already been drawn. 
(defparameter *datum-table* nil)

(defun datum-id (datum)
  (gethash datum *datum-table*))

(defmethod draw-datum :around (datum stream)
  (when (null (datum-id datum))
    (setf (gethash datum *datum-table*) (gensym))
    (call-next-method)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum CONSTANT-INPUT.

(defmethod draw-datum ((datum constant-input) stream)
  (format stream "  ~a [shape = ellipse, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = green, label = \"~a\"]~%"
	  (datum-id datum) (value datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum LEXICAL-LOCATION.

(defmethod draw-datum ((datum lexical-location) stream)
  (format stream "  ~a [shape = ellipse, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = yellow, label = \"~a\"]~%"
	  (datum-id datum) (name datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum DYNAMIC-LEXICAL-LOCATION.

(defmethod draw-datum ((datum dynamic-lexical-location) stream)
  (format stream "  ~a [shape = hexagon, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = yellow, label = \"~a\"]~%"
	  (datum-id datum) (name datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum STATIC-LEXICAL-LOCATION.

(defmethod draw-datum ((datum static-lexical-location) stream)
  (format stream "  ~a [shape = octagon, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = yellow, label = \"~a\"]~%"
	  (datum-id datum) (name datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum VALUES-LOCATION.

(defmethod draw-datum ((datum values-location) stream)
  (format stream "  ~a [shape = ellipse, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = blue, label = \"V\"]~%"
	  (datum-id datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing datum IMMEDIATE-INPUT.

(defmethod draw-datum ((datum immediate-input) stream)
  (format stream "  ~a [shape = ellipse, style = filled];~%"
	  (datum-id datum))
  (format stream "   ~a [fillcolor = aquamarine, label = \"~a\"]~%"
	  (datum-id datum) (value datum)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Drawing instructions.

(defparameter *instruction-table* nil)

(defun instruction-id (instruction)
  (gethash instruction *instruction-table*))

(defgeneric draw-instruction (instruction stream))
  
(defmethod draw-instruction :around (instruction stream)
  (when (null (instruction-id instruction))
    (setf (gethash instruction *instruction-table*) (gensym))
    (format stream "  ~a [shape = box];~%"
	    (instruction-id instruction))
    (call-next-method)))

(defmethod draw-instruction :before ((instruction instruction) stream)
  (loop for next in (successors instruction)
	do (draw-instruction next stream))
  (loop for next in (successors instruction)
	for i from 1
	do (format stream
		   "  ~a -> ~a [style = bold, label = \"~d\"];~%"
		   (instruction-id instruction)
		   (gethash next *instruction-table*)
		   i)))
  
(defmethod draw-instruction :after (instruction stream)
  (loop for datum in (inputs instruction)
	for i from 1
	do (draw-datum datum stream)
	   (format stream
		   "  ~a -> ~a [color = red, style = dashed, label = \"~d\"];~%"
		   (datum-id datum)
		   (instruction-id instruction)
		   i))
  (loop for datum in (outputs instruction)
	for i from 1
	do (draw-datum datum stream)
	   (format stream
		   "  ~a -> ~a [color = blue, style = dashed, label = \"~d\"];~%"
		   (instruction-id instruction)
		   (datum-id datum)
		   i)))

(defgeneric label (instruction))

(defmethod label (instruction)
  (class-name (class-of instruction)))

(defmethod draw-instruction (instruction stream)
  (format stream "   ~a [label = \"~a\"];~%"
	  (instruction-id instruction)
	  (label instruction)))

(defun draw-flowchart (start filename)
  (with-open-file (stream filename
			  :direction :output
			  :if-exists :supersede)
    (let ((*instruction-table* (make-hash-table :test #'eq))
	  (*datum-table* (make-hash-table :test #'eq)))
      (format stream "digraph G {~%")
      (format stream "   start [label = \"START\"];~%")
      (draw-instruction start stream)
      (format stream "start -> ~a [style = bold];~%"
	      (instruction-id start))
      (format stream "}~%"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General-purpose instructions.

(defmethod draw-instruction ((instruction typeq-instruction) stream)
  (format stream "   ~a [label = \"typeq ~a\"];~%"
	  (instruction-id instruction)
	  (value-type instruction)))

(defun format-item (item)
  (cond ((symbolp item)
	 item)
	((listp item)
	 (mapcar #'format-item item))
	((typep item 'cleavir-ir:lexical-location)
	 (cleavir-ir:name item))
	(t
	 (error "unknown item in lambda list ~s" item))))

(defmethod label ((instruction enter-instruction))
  (with-output-to-string (stream)
    (format stream "enter ~a"
	    (mapcar #'format-item (cleavir-ir:lambda-list instruction)))))

(defmethod label ((instruction nop-instruction)) "nop")

(defmethod label ((instruction assignment-instruction)) "<-")

(defmethod label ((instruction funcall-instruction)) "funcall")

(defmethod label ((instruction tailcall-instruction)) "tailcall")

(defmethod label ((instruction return-instruction)) "ret")

(defmethod label ((instruction fdefinition-instruction)) "fdefinition")

(defmethod draw-instruction ((instruction enclose-instruction) stream)
  (format stream "   ~a [label = \"enclose\"];~%"
	  (instruction-id instruction))
  (draw-instruction (code instruction) stream)
  (format stream "  ~a -> ~a [color = pink, style = dashed];~%"
	  (gethash (code instruction) *instruction-table*)
	  (instruction-id instruction)))

(defmethod draw-instruction ((instruction unwind-instruction) stream)
  (format stream "   ~a [label = \"unwind\"];~%"
	  (instruction-id instruction))
  (format stream "  ~a -> ~a [color = pink, style = dashed];~%"
	  (instruction-id instruction)
	  (gethash (invocation instruction) *instruction-table*)))

(defmethod label ((instruction catch-instruction)) "catch")

(defmethod label ((instruction eq-instruction)) "eq")

(defmethod label ((instruction phi-instruction)) "phi")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Fixnum instructions.

(defmethod label ((instruction fixnum-add-instruction)) "fixnum +")

(defmethod label ((instruction fixnum-sub-instruction)) "fixnum -")

(defmethod label ((instruction fixnum-less-instruction)) "fixnum <")

(defmethod label ((instruction fixnum-not-greater-instruction)) "fixnum <=")

(defmethod label ((instruction fixnum-equal-instruction)) "fixnum =")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Integer instructions.

(defmethod label ((instruction bit-unbox-instruction)) "bit unbox")

(defmethod label ((instruction bit-box-instruction)) "bit box")

(defmethod label ((instruction unsigned-byte-8-unbox-instruction)) "ub8 unbox")

(defmethod label ((instruction unsigned-byte-8-box-instruction)) "ub8 box")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Floating-point arithmetic instructions.

(defmethod label ((instruction short-float-unbox-instruction)) "shf unbox")

(defmethod label ((instruction short-float-box-instruction)) "shf box")

(defmethod label ((instruction short-float-add-instruction)) "shf +")

(defmethod label ((instruction short-float-sub-instruction)) "shf -")

(defmethod label ((instruction short-float-mul-instruction)) "shf *")

(defmethod label ((instruction short-float-div-instruction)) "shf /")

(defmethod label ((instruction short-float-sin-instruction)) "shf sin")

(defmethod label ((instruction short-float-cos-instruction)) "shf cos")

(defmethod label ((instruction short-float-sqrt-instruction)) "shf sqrt")

(defmethod label ((instruction single-float-unbox-instruction)) "sf unbox")

(defmethod label ((instruction single-float-box-instruction)) "sf box")

(defmethod label ((instruction single-float-add-instruction)) "sf +")

(defmethod label ((instruction single-float-sub-instruction)) "sf -")

(defmethod label ((instruction single-float-mul-instruction)) "sf *")

(defmethod label ((instruction single-float-div-instruction)) "sf /")

(defmethod label ((instruction single-float-sin-instruction)) "sf sin")

(defmethod label ((instruction single-float-cos-instruction)) "sf cos")

(defmethod label ((instruction single-float-sqrt-instruction)) "sf sqrt")

(defmethod label ((instruction double-float-unbox-instruction)) "df unbox")

(defmethod label ((instruction double-float-box-instruction)) "df box")

(defmethod label ((instruction double-float-add-instruction)) "df +")

(defmethod label ((instruction double-float-sub-instruction)) "df -")

(defmethod label ((instruction double-float-mul-instruction)) "df *")

(defmethod label ((instruction double-float-div-instruction)) "df /")

(defmethod label ((instruction double-float-sin-instruction)) "df sin")

(defmethod label ((instruction double-float-cos-instruction)) "df cos")

(defmethod label ((instruction double-float-sqrt-instruction)) "df sqrt")

(defmethod label ((instruction long-float-unbox-instruction)) "df unbox")

(defmethod label ((instruction long-float-box-instruction)) "df box")

(defmethod label ((instruction long-float-add-instruction)) "lf +")

(defmethod label ((instruction long-float-sub-instruction)) "lf -")

(defmethod label ((instruction long-float-mul-instruction)) "lf *")

(defmethod label ((instruction long-float-div-instruction)) "lf /")

(defmethod label ((instruction long-float-sin-instruction)) "lf sin")

(defmethod label ((instruction long-float-cos-instruction)) "lf cos")

(defmethod label ((instruction long-float-sqrt-instruction)) "lf sqrt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; General accessors.

(defmethod label ((instruction car-instruction)) "car")

(defmethod label ((instruction cdr-instruction)) "cdr")

(defmethod label ((instruction rplaca-instruction)) "rplaca")

(defmethod label ((instruction rplacd-instruction)) "rplacd")

(defmethod label ((instruction slot-read-instruction)) "rplacd")

(defmethod label ((instruction slot-write-instruction)) "rplacd")

(defmethod label ((instruction t-aref-instruction)) "t aref")

(defmethod label ((instruction t-aset-instruction)) "t aset")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Integer array accessors.

(defmethod label ((instruction bit-aref-instruction)) "bit aref")

(defmethod label ((instruction bit-aset-instruction)) "bit aset")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Floating-point array accessors.

(defmethod label ((instruction short-float-aref-instruction)) "shf aref")

(defmethod label ((instruction single-float-aref-instruction)) "sf aref")

(defmethod label ((instruction double-float-aref-instruction)) "df aref")

(defmethod label ((instruction long-float-aref-instruction)) "lf aref")

(defmethod label ((instruction short-float-aset-instruction)) "shf aset")

(defmethod label ((instruction single-float-aset-instruction)) "sf aset")

(defmethod label ((instruction double-float-aset-instruction)) "df aset")

(defmethod label ((instruction long-float-aset-instruction)) "lf aset")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Instructions for multiple values.

(defmethod label ((instruction multiple-to-fixed-instruction)) "M->F")

(defmethod label ((instruction fixed-to-multiple-instruction)) "F->M")

(defmethod label ((instruction multiple-value-call-instruction)) "MVC")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Instructions related to the static runtime environment.

(defmethod label ((instruction create-cell-instruction)) "Create cell")

(defmethod label ((instruction fetch-instruction)) "Fetch")

(defmethod label ((instruction read-cell-instruction)) "Read cell")

(defmethod label ((instruction write-cell-instruction)) "Write cell")

(defmethod label ((instruction add-activation-record-instruction)) "AddAR")

(defmethod label ((instruction remove-activation-record-instruction)) "RemAR")

(defmethod label ((instruction load-from-static-environment-instruction))
  "Load")

(defmethod label ((instruction store-to-static-environment-instruction))
  "Store")
