(in-package #:sicl-sequence)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Tools for writing compiler macros.

;;; Preserving order of evaluation with a compiler macro gets
;;; complicated.  The left-to-right order in the original 
;;; call must be respected.  So for instance, if we have 
;;; a call such as (find-if p s :key <x> :end <y> :start <z>)
;;; the expressions <x>, <y>, and <z> must be evaluated in
;;; that order.  One solution to this problem is to generate
;;; code such as (let ((key <x>) (end <y>) (start <z>)) ...)
;;; and then use the variables key, end, start in the body of
;;; the let.  However, things are a bit more complicated, 
;;; because section 3.4.1.4 of the HyperSpec says that there
;;; can be multiple occurences of a keyword in a call, so that
;;; (find-if p s :key <x> :end <y> :start <z> :key <w>) is
;;; legal.  In this case, <w> must be evaluated last, but 
;;; the value of the :key argument is the value of <x>.  
;;; So we must handle multiple occurences by generating something
;;; like (let ((key <x>) (end <y>) (start <z>) (ignore <w>)) ...) 
;;; where ignore is a unique symbol.  But we must also preserve 
;;; that symbol for later so that we can declare it to be ignored
;;; in order to avoid compiler warnings. 

;;; Yet another complication happens because if the call contains
;;; :allow-other-keys t, then pretty much any other keyword can be 
;;; present.  Again, we generate a unique symbol for that case. 

;;; Things are further complicated by the fact that the special
;;; versions of many functions always take a start parameter.  If
;;; the call doesn't have a :start keyword argument, we need to 
;;; initialize start to 0. 

;;; Translate from a keyword to a variable name
(defparameter *vars* '((:start . start)
                       (:end . end)
                       (:from-end . from-end)
                       (:key . key)
                       (:test . test)
                       (:test-not . test-not)
                       (:count . count)))

;;; For a list with alternating keywords, and expressions, 
;;; generate a list of binding for let.  For instance,
;;; if we have (:key <x> :end <y> :start <z>), we generate
;;; ((key <x>) (end <y>) (start <z>)).  If a keyword occurs 
;;; more than once in the list, generate a binding with a 
;;; generated symbol instead. 
(defun make-bindings (plist)
  (loop with keywords = '()
        for (key value) on plist by #'cddr
        collect (list (if (member key keywords)
                          (gensym)
                          (or (cdr (assoc key *vars*)) (gensym)))
                      value)
        do (push key keywords)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Utilities

;;; Skip a prefix of a list and signal an error if the list is too
;;; short, or if it is not a proper list.  Also check that start is a
;;; nonnegative integer.
(defun skip-to-start (name list start)
  (let ((start-bis start)
	(remaining list))
    (loop until (zerop start-bis)
	  until (atom remaining)
	  do (setf remaining (cdr remaining))
	     (decf start-bis)
	  finally (when (and (atom remaining) (not (null remaining)))
		    (error 'must-be-proper-list
			   :name name
			   :datum list))
		  (when (plusp start-bis)
		    (error 'invalid-start-index
			   :name name
			   :datum start
			   :expected-type `(integer 0 ,(- start start-bis))
			   :in-sequence list)))
    remaining))

;;; This function is called at the end of some list traversal
;;; to make sure that the list is a proper list.
(defun tail-must-be-proper-list (name list tail)
  (when (and (atom tail) (not (null tail)))
    (error 'must-be-proper-list
	   :name name
	   :datum list)))

;;; This function is called at the end of some list traversal
;;; to make sure that the list is a proper list, and to make sure
;;; that end is a valid index.
(defun tail-must-be-proper-list-with-end (name list tail end length)
  (when (and (atom tail) (not (null tail)))
    (error 'must-be-proper-list
	   :name name
	   :datum list))
  (when (and (atom tail) (< length end))
    (error 'invalid-end-index
	   :name name
	   :datum end
	   :in-sequence list
	   :expected-type `(integer 0 ,length))))

;;; This function is used when the sequence is a vector of some kind
;;; in order to verify that start and end are valid bounding indexes.
;;; It has already been verified that start is a nonnegative integer.
;;; FIXME: What do we know about end?
(defun verify-bounding-indexes (name vector start end)
  (let ((length (length vector)))
    (when (> start length)
      (error 'invalid-start-index
	     :name name
	     :datum start
	     :expected-type `(integer 0 ,length)
	     :in-sequence vector))
    (unless (<= 0 end length)
      (error 'invalid-end-index
	     :name name
	     :datum end
	     :expected-type `(integer 0 ,length)
	     :in-sequence vector))
    (unless (<= start end)
      (error 'end-less-than-start
	     :name name
	     :datum start
	     :expected-type `(integer 0 ,end)
	     :end-index end
	     :in-sequence vector))))

;;; This function is used to compute the length of the list
;;; given a remainder and a start index.
(defun compute-length-from-remainder (name list remainder start)
  (loop for length from start
	until (atom remainder)
	do (setf remainder (cdr remainder))
	finally (unless (null remainder)
		  (error 'must-be-proper-list
			 :name name
			 :datum list))
		(return length)))

;;; This function is used to verify that the end sequence index
;;; is valid, and that, if we reach the end of the list, it is 
;;; a proper list.  The remainder of the list is returned.
(defun verify-end-index (name list remainder start end)
  (loop for length from start
	until (or (atom remainder) (>= length end))
	do (setf remainder (cdr remainder))
	   finally (unless (or (null remainder) (consp remainder))
		     (error 'must-be-proper-list
			 :name name
			 :datum list))
		   (when (< length end)
		     (error 'invalid-end-index
			    :name name
			    :datum end
			    :expect-type `(integer 0 ,length)
			    :in-sequence list))
		   (return remainder)))

;;; When we traverse a list from the end, we use the recursion stack
;;; to visit elements during backtrack.  However, because the stacks
;;; might have limited depth, we make sure we only use a fixed number
;;; of recursive calls.  This parameter indicates how many recursive
;;; calls we are allowed to use.  In fact, we will probably use up to
;;; 4 times as many recursions as that.  Implementations should set
;;; this as large as possible, but it should be significantly smaller
;;; than any hard limit on the recursion depth to allow for our
;;; traversal to be invoked when the stack already has some
;;; invocations on it.
(defparameter *max-recursion-depth* 100)

;;; The basic traversal technique is as follows.  We divide the list
;;; into chunks such that there are no more than c <= m chunks and
;;; each chunk has the a size of m^k where m is the "maximum"
;;; recursion depth allowed and k is the smallest nonnegative integer
;;; that makes c <= m.  We then handle each chunk on the backtrack
;;; side of a recursive call, so that the last chunk is handled first.
;;; Each chunk is then handled the same way, but this time with a
;;; sub-chunk size of m^(k-1), etc, until the sub-chunk size is 1 at
;;; which point we call a function traverse-list-1 which was passed in
;;; as an argument. 
(defun traverse-list (traverse-list-1 list length step)
  (let ((max-recursion-depth *max-recursion-depth*))
    (labels ((aux (list length step)
	       (cond ((> (ceiling length step) max-recursion-depth)
		      (aux list length (* step max-recursion-depth)))
		     ((= step 1)
		      (funcall traverse-list-1 list length))
		     ((<= length step)
		      (aux list length (/ step max-recursion-depth)))
		     (t
		      (aux (nthcdr step list) (- length step) step)
		      (aux list step (/ step max-recursion-depth))))))
      (aux list length step))))

;;; This function copies a prefix of a list and returns three values:
;;; A sentinel cons cell at the beginning of the copied list in case
;;; the prefix to copy is empty, the last cell of the copied prefix,
;;; or the sentinel if the prefix to copy is empty, and the remainder
;;; of the list when the prefix has been removed.  We verify whenever
;;; possible that the list is a proper list.  We also verify that the
;;; length of the list is greater than or equal to the prefix length. 
(defun copy-prefix (name list start)
  (let* ((sentinel (list nil))
	 (last sentinel))
    (loop for index from 0
	  for remaining = list then (cdr remaining)
	  until (or (atom remaining) (>= index start))
	  do (setf (cdr last) (cons (car remaining) nil))
	     (setf last (cdr last))
	  finally (unless (or (null remaining) (consp remaining))
		    (error 'must-be-proper-list
			   :name name
			   :datum list))
		  (return (values sentinel last remaining)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function find

;;; Instead of hand-writing every possible combination
;;; of find, we'll use a macro to create these functions.

(defparameter +find-function-name-format-control+
  "find seq-type=~a from-end=~a ~@[end=~a ~]~
        ~@[test=~a~]~@[test-not=~a~] key=~a")

(defmacro define-find-list-variant
    (&key end
          from-end
          (test     nil test-suppliedp)
          (test-not nil test-not-suppliedp)
          key)
  (let ((function-name
          (intern (string-downcase
                   (format nil +find-function-name-format-control+
                           'list from-end (or end "nil")
                           ;; "nil" because otherwise
                           ;; format will exclude end= alltogether
                           (and test-suppliedp test)
                           (and test-not-suppliedp test-not)
                           key))))
        (function-args `(item list start
                              ,@(ecase end
                                  ((nil) nil)
                                  (other '(end)))
                              ,@(if test-suppliedp
                                    (ecase test
                                      ((eq eql) nil)
                                      (other '(test))))
                              ,@(if test-not-suppliedp
                                    (ecase test-not
                                      ((eq eql) nil)
                                      (other '(test))))
                              ,@(ecase key
                                  (identity nil)
                                  (other '(key))))))
    `(defun ,function-name ,function-args
       (loop ,@(ecase from-end
                 (false nil)
                 (true '(with value = nil))) 
             ,@(ecase end
                 ((nil) nil)
                 (other '(for index from start)))
             for remaining = (skip-to-start 'find list start)
               then (cdr remaining)
             until ,(ecase end
                      ((nil) '(atom remaining))
                      (other '(or (atom remaining) (>= index end)))) 
             for element = (car remaining)
             when ,(let ((key-code
                           (ecase key
                             (identity 'element)
                             (other '(funcall key element)))))
                     (cond
                       (test-suppliedp
                        (ecase test
                          ((eq eql) `(,test item ,key-code))
                          (other `(funcall test item ,key-code))))
                       (test-not-suppliedp
                        (ecase test-not
                          ((eq eql) `(not (,test-not item ,key-code)))
                          (other `(not (funcall test item ,key-code)))))
                       (t (error "Supply test."))))
               ,@(ecase from-end
                   (false '(return element))
                   (true '(do (setf value element))))
             finally
             ,(ecase end
                ((nil) '(tail-must-be-proper-list 'find list remaining))
                (other '(tail-must-be-proper-list-with-end
                         'find list remaining end index)))
             ,@(ecase from-end
                 (false nil)
                 (true '((return value))))))))

(define-find-list-variant :from-end false :end nil :test eq :key identity)
(define-find-list-variant :from-end false :end nil :test eq :key other)
(define-find-list-variant :from-end false :end nil :test-not eq :key identity)
(define-find-list-variant :from-end false :end nil :test-not eq :key other)
(define-find-list-variant :from-end false :end nil :test eql :key identity)
(define-find-list-variant :from-end false :end nil :test eql :key other)
(define-find-list-variant :from-end false :end nil :test-not eql :key identity)
(define-find-list-variant :from-end false :end nil :test-not eql :key other)
(define-find-list-variant :from-end false :end nil :test other :key identity)
(define-find-list-variant :from-end false :end nil :test other :key other)
(define-find-list-variant :from-end false :end nil :test-not other :key identity)
(define-find-list-variant :from-end false :end nil :test-not other :key other)
(define-find-list-variant :from-end false :end other :test eq :key identity)
(define-find-list-variant :from-end false :end other :test eq :key other)
(define-find-list-variant :from-end false :end other :test-not eq :key identity)
(define-find-list-variant :from-end false :end other :test-not eq :key other)
(define-find-list-variant :from-end false :end other :test eql :key identity)
(define-find-list-variant :from-end false :end other :test eql :key other)
(define-find-list-variant :from-end false :end other :test-not eql :key identity)
(define-find-list-variant :from-end false :end other :test-not eql :key other)
(define-find-list-variant :from-end false :end other :test other :key identity)
(define-find-list-variant :from-end false :end other :test other :key other)
(define-find-list-variant :from-end false :end other :test-not other :key identity)
(define-find-list-variant :from-end false :end other :test-not other :key other)

;;; We do not supply a special version for
;;; seq-type=list from-end=true end=nil test=eq key=identity
;;; because there is no way to distinguish between the
;;; eq elements of the list, so we might as well take the first one
;;; as in the case from-end=false

(define-find-list-variant :from-end true :end nil :test eq :key other)
(define-find-list-variant :from-end true :end nil :test-not eq :key identity)
(define-find-list-variant :from-end true :end nil :test-not eq :key other)

;;; We do not supply a special version for
;;; seq-type=list from-end=true end=nil test=eql key=identity
;;; because there is no way to distinguish between the
;;; eql elements of the list, so we might as well take the first one
;;; as in the case from-end=false

(define-find-list-variant :from-end true :end nil :test eql :key other)
(define-find-list-variant :from-end true :end nil :test-not eql :key identity)
(define-find-list-variant :from-end true :end nil :test-not eql :key other)
(define-find-list-variant :from-end true :end nil :test other :key identity)
(define-find-list-variant :from-end true :end nil :test other :key other)
(define-find-list-variant :from-end true :end nil :test-not other :key identity)
(define-find-list-variant :from-end true :end nil :test-not other :key other)

;;; We do not supply a special version for
;;; seq-type=list from-end=true end=other test=eq key=identity
;;; because there is no way to distinguish between the
;;; eq elements of the list, so we might as well take the first one
;;; as in the case from-end=false

(define-find-list-variant :from-end true :end other :test eq :key other)
(define-find-list-variant :from-end true :end other :test-not eq :key identity)
(define-find-list-variant :from-end true :end other :test-not eq :key other)

;;; We do not supply a special version for
;;; seq-type=list from-end=true end=other test=eql key=identity
;;; because there is no way to distinguish between the
;;; eql elements of the list, so we might as well take the first one
;;; as in the case from-end=false

(define-find-list-variant :from-end true :end other :test eql :key other)
(define-find-list-variant :from-end true :end other :test-not eql :key identity)
(define-find-list-variant :from-end true :end other :test-not eql :key other)
(define-find-list-variant :from-end true :end other :test other :key identity)
(define-find-list-variant :from-end true :end other :test other :key other)
(define-find-list-variant :from-end true :end other :test-not other :key identity)
(define-find-list-variant :from-end true :end other :test-not other :key other)

(defmacro define-find-vector-variant
    (&key from-end
          (test     nil test-suppliedp)
          (test-not nil test-not-suppliedp)
          key)
  (let ((function-name
          (intern (string-downcase
                   (format nil +find-function-name-format-control+
                           'vector from-end nil
                           (and test-suppliedp test)
                           (and test-not-suppliedp test-not)
                           key))))
        (function-args `(item vector start end
                              ,@(if test-suppliedp
                                    (ecase test
                                      ((eq eql) nil)
                                      (other '(test))))
                              ,@(if test-not-suppliedp
                                    (ecase test-not
                                      ((eq eql) nil)
                                      (other '(test))))
                              ,@(ecase key
                                  (identity nil)
                                  (other '(key))))))
    `(defun ,function-name ,function-args
       (loop ,@(ecase from-end
                 (false '(for index from start below end))
                 (true '(for index downfrom (1- end) to start))) 
             when ,(let ((key-code
                           (ecase key
                             (identity '(aref vector index))
                             (other '(funcall key (aref vector index))))))
                     (cond
                       (test-suppliedp
                        (ecase test
                          ((eq eql) `(,test item ,key-code))
                          (other `(funcall test item ,key-code))))
                       (test-not-suppliedp
                        (ecase test-not
                          ((eq eql) `(not (,test-not item ,key-code)))
                          (other `(not (funcall test item ,key-code)))))
                       (t (error "Supply test"))))
               return (aref vector index)))))

(define-find-vector-variant :from-end false :test eq :key identity)
(define-find-vector-variant :from-end false :test-not eq :key other)
(define-find-vector-variant :from-end false :test eql :key identity)
(define-find-vector-variant :from-end false :test-not eql :key other)
(define-find-vector-variant :from-end false :test other :key identity)
(define-find-vector-variant :from-end false :test other :key other)

(define-find-vector-variant :from-end true :test eq :key identity)
(define-find-vector-variant :from-end true :test-not eq :key other)
(define-find-vector-variant :from-end true :test eql :key identity)
(define-find-vector-variant :from-end true :test-not eql :key other)
(define-find-vector-variant :from-end true :test other :key identity)
(define-find-vector-variant :from-end true :test other :key other)

(defun |find from-end=false end=nil test=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=false end=nil test=eq key=identity|
        item sequence start))))

(defun |find from-end=false end=nil test=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=false end=nil test=eq key=other|
        item sequence start key))))

(defun |find from-end=false end=nil test-not=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=false end=nil test-not=eq key=identity|
        item sequence start))))

(defun |find from-end=false end=nil test-not=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=false end=nil test-not=eq key=other|
        item sequence start key))))

(defun |find from-end=false end=nil test=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=false end=nil test=eql key=identity|
        item sequence start))))

(defun |find from-end=false end=nil test=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=false end=nil test=eql key=other|
        item sequence start key))))

(defun |find from-end=false end=nil test-not=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=false end=nil test-not=eql key=identity|
        item sequence start))))

(defun |find from-end=false end=nil test-not=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=false end=nil test-not=eql key=other|
        item sequence start key))))

(defun |find from-end=false end=nil test=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|find seq-type=list from-end=false end=nil test=other key=identity|
        item sequence start test))))

(defun |find from-end=false end=nil test=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|find seq-type=list from-end=false end=nil test=other key=other|
        item sequence start test key))))

(defun |find from-end=false end=nil test-not=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|find seq-type=list from-end=false end=nil test-not=other key=identity|
        item sequence start test))))

(defun |find from-end=false end=nil test-not=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from=end=nil test-not=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|find seq-type=list from-end=false end=nil test-not=other key=other|
        item sequence start test key))))

(defun |find from-end=false end=other test=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=eq key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=false end=other test=eq key=identity|
        item sequence start end))))

(defun |find from-end=false end=other test=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=eq key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=false end=other test=eq key=other|
        item sequence start end key))))

(defun |find from-end=false end=other test-not=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=eq key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=false end=other test-not=eq key=identity|
        item sequence start end))))

(defun |find from-end=false end=other test-not=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=eq key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=false end=other test-not=eq key=other|
        item sequence start end key))))

(defun |find from-end=false end=other test=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=eql key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=false end=other test=eql key=identity|
        item sequence start end))))

(defun |find from-end=false end=other test=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=eql key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=false end=other test=eql key=other|
        item sequence start end key))))

(defun |find from-end=false end=other test-not=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=eql key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=false end=other test-not=eql key=identity|
        item sequence start end))))

(defun |find from-end=false end=other test-not=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=eql key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=false end=other test-not=eql key=other|
        item sequence start end key))))

(defun |find from-end=false end=other test=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=other key=identity|
        item sequence start end test))
    (list
       (|find seq-type=list from-end=false end=other test=other key=identity|
        item sequence start end test))))

(defun |find from-end=false end=other test=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test=other key=other|
        item sequence start end test key))
    (list
       (|find seq-type=list from-end=false end=other test=other key=other|
        item sequence start end test key))))

(defun |find from-end=false end=other test-not=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=other key=identity|
        item sequence start end test))
    (list
       (|find seq-type=list from-end=false end=other test-not=other key=identity|
        item sequence start end test))))

(defun |find from-end=false end=other test-not=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from=end=nil test-not=other key=other|
        item sequence start end test key))
    (list
       (|find seq-type=list from-end=false end=other test-not=other key=other|
        item sequence start end test key))))

(defun |find from-end=true end=nil test=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=eq key=identity|
        item sequence start (length sequence)))
    (list
       ;; We use from-end=false instead because there is no way
       ;; to tell the difference. 
       (|find seq-type=list from-end=false end=nil test=eq key=identity|
        item sequence start))))

(defun |find from-end=true end=nil test=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=true end=nil test=eq key=other|
        item sequence start key))))

(defun |find from-end=true end=nil test-not=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=true end=nil test-not=eq key=identity|
        item sequence start))))

(defun |find from-end=true end=nil test-not=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=true end=nil test-not=eq key=other|
        item sequence start key))))

(defun |find from-end=true end=nil test=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=eql key=identity|
        item sequence start (length sequence)))
    (list
       ;; We use from-end=false instead because there is no way
       ;; to tell the difference. 
       (|find seq-type=list from-end=false end=nil test=eql key=identity|
        item sequence start))))

(defun |find from-end=true end=nil test=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=true end=nil test=eql key=other|
        item sequence start key))))

(defun |find from-end=true end=nil test-not=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|find seq-type=list from-end=true end=nil test-not=eql key=identity|
        item sequence start))))

(defun |find from-end=true end=nil test-not=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|find seq-type=list from-end=true end=nil test-not=eql key=other|
        item sequence start key))))

(defun |find from-end=true end=nil test=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|find seq-type=list from-end=true end=nil test=other key=identity|
        item sequence start test))))

(defun |find from-end=true end=nil test=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|find seq-type=list from-end=true end=nil test=other key=other|
        item sequence start test key))))

(defun |find from-end=true end=nil test-not=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|find seq-type=list from-end=true end=nil test-not=other key=identity|
        item sequence start test))))

(defun |find from-end=true end=nil test-not=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start (length sequence))
       (|find seq-type=vector from-end=true test-not=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|find seq-type=list from-end=true end=nil test-not=other key=other|
        item sequence start test key))))

(defun |find from-end=true end=other test=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=eq key=identity|
        item sequence start end))
    (list
       ;; We use from-end=false instead because there is no way
       ;; to tell the difference. 
       (|find seq-type=list from-end=false end=other test=eq key=identity|
        item sequence start end))))

(defun |find from-end=true end=other test=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=eq key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=true end=other test=eq key=other|
        item sequence start end key))))

(defun |find from-end=true end=other test-not=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=eq key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=true end=other test-not=eq key=identity|
        item sequence start end))))

(defun |find from-end=true end=other test-not=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=eq key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=true end=other test-not=eq key=other|
        item sequence start end key))))

(defun |find from-end=true end=other test=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=eql key=identity|
        item sequence start end))
    (list
       ;; We use from-end=false instead because there is no way
       ;; to tell the difference
       (|find seq-type=list from-end=false end=other test=eql key=identity|
        item sequence start end))))

(defun |find from-end=true end=other test=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=eql key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=true end=other test=eql key=other|
        item sequence start end key))))

(defun |find from-end=true end=other test-not=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=eql key=identity|
        item sequence start end))
    (list
       (|find seq-type=list from-end=true end=other test-not=eql key=identity|
        item sequence start end))))

(defun |find from-end=true end=other test-not=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=eql key=other|
        item sequence start end key))
    (list
       (|find seq-type=list from-end=true end=other test-not=eql key=other|
        item sequence start end key))))

(defun |find from-end=true end=other test=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=other key=identity|
        item sequence start end test))
    (list
       (|find seq-type=list from-end=true end=other test=other key=identity|
        item sequence start end test))))

(defun |find from-end=true end=other test=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test=other key=other|
        item sequence start end test key))
    (list
       (|find seq-type=list from-end=true end=other test=other key=other|
        item sequence start end test key))))

(defun |find from-end=true end=other test-not=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=other key=identity|
        item sequence start end test))
    (list
       (|find seq-type=list from-end=true end=other test-not=other key=identity|
        item sequence start end test))))

(defun |find from-end=true end=other test-not=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find sequence start end)
       (|find seq-type=vector from-end=true test-not=other key=other|
        item sequence start end test key))
    (list
       (|find seq-type=list from-end=true end=other test-not=other key=other|
        item sequence start end test key))))

(defun find (item sequence
             &key
             from-end
             (test nil test-p)
             (test-not nil test-not-p)
             (start 0)
             end
             key)
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'find
	   :datum start
	   :expected-type '(integer 0)))
  (when (and test-p test-not-p)
    (error 'both-test-and-test-not-given
	   :name 'find))
  (if from-end
      (if key
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=true end=other test=eql key=other|
                       item sequence start end key)
                      (if (eq test #'eq)
                          (|find from-end=true end=other test=eq key=other|
                           item sequence start end key)
                          (|find from-end=true end=other test=other key=other|
                           item sequence start end test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=true end=other test-not=eql key=other|
                           item sequence start end key)
                          (if (eq test-not #'eq)
                              (|find from-end=true end=other test-not=eq key=other|
                               item sequence start end key)
                              (|find from-end=true end=other test-not=other key=other|
                               item sequence start end test-not key)))
                      (|find from-end=true end=other test=eql key=other|
                       item sequence start end key)))
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=true end=nil test=eql key=other|
                       item sequence start key)
                      (if (eq test #'eq)
                          (|find from-end=true end=nil test=eq key=other|
                           item sequence start key)
                          (|find from-end=true end=nil test=other key=other|
                           item sequence start test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=true end=nil test-not=eql key=other|
                           item sequence start key)
                          (if (eq test-not #'eq)
                              (|find from-end=true end=nil test-not=eq key=other|
                               item sequence start key)
                              (|find from-end=true end=nil test-not=other key=other|
                               item sequence start test-not key)))
                      (|find from-end=true end=nil test=eql key=other|
                       item sequence start key))))
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=true end=other test=eql key=identity|
                       item sequence start end)
                      (if (eq test #'eq)
                          (|find from-end=true end=other test=eq key=identity|
                           item sequence start end)
                          (|find from-end=true end=other test=other key=identity|
                           item sequence start end test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=true end=other test-not=eql key=identity|
                           item sequence start end)
                          (if (eq test-not #'eq)
                              (|find from-end=true end=other test-not=eq key=identity|
                               item sequence start end)
                              (|find from-end=true end=other test-not=other key=identity|
                               item sequence start end test-not)))
                      (|find from-end=true end=other test=eql key=identity|
                       item sequence start end)))
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=true end=nil test=eql key=identity|
                       item sequence start)
                      (if (eq test #'eq)
                          (|find from-end=true end=nil test=eq key=identity|
                           item sequence start)
                          (|find from-end=true end=nil test=other key=identity|
                           item sequence start test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=true end=nil test-not=eql key=identity|
                           item sequence start)
                          (if (eq test-not #'eq)
                              (|find from-end=true end=nil test-not=eq key=identity|
                               item sequence start)
                              (|find from-end=true end=nil test-not=other key=identity|
                               item sequence start test-not)))
                      (|find from-end=true end=nil test=eql key=identity|
                       item sequence start)))))
      (if key
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=false end=other test=eql key=other|
                       item sequence start end key)
                      (if (eq test #'eq)
                          (|find from-end=false end=other test=eq key=other|
                           item sequence start end key)
                          (|find from-end=false end=other test=other key=other|
                           item sequence start end test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=false end=other test-not=eql key=other|
                           item sequence start end key)
                          (if (eq test-not #'eq)
                              (|find from-end=false end=other test-not=eq key=other|
                               item sequence start end key)
                              (|find from-end=false end=other test-not=other key=other|
                               item sequence start end test-not key)))
                      (|find from-end=false end=other test=eql key=other|
                       item sequence start end key)))
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=false end=nil test=eql key=other|
                       item sequence start key)
                      (if (eq test #'eq)
                          (|find from-end=false end=nil test=eq key=other|
                           item sequence start key)
                          (|find from-end=false end=nil test=other key=other|
                           item sequence start test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=false end=nil test-not=eql key=other|
                           item sequence start key)
                          (if (eq test-not #'eq)
                              (|find from-end=false end=nil test-not=eq key=other|
                               item sequence start key)
                              (|find from-end=false end=nil test-not=other key=other|
                               item sequence start test-not key)))
                      (|find from-end=false end=nil test=eql key=other|
                       item sequence start key))))
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=false end=other test=eql key=identity|
                       item sequence start end)
                      (if (eq test #'eq)
                          (|find from-end=false end=other test=eq key=identity|
                           item sequence start end)
                          (|find from-end=false end=other test=other key=identity|
                           item sequence start end test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=false end=other test-not=eql key=identity|
                           item sequence start end)
                          (if (eq test-not #'eq)
                              (|find from-end=false end=other test-not=eq key=identity|
                               item sequence start end)
                              (|find from-end=false end=other test-not=other key=identity|
                               item sequence start end test-not)))
                      (|find from-end=false end=other test=eql key=identity|
                       item sequence start end)))
              (if test-p
                  (if (eq test #'eql)
                      (|find from-end=false end=nil test=eql key=identity|
                       item sequence start)
                      (if (eq test #'eq)
                          (|find from-end=false end=nil test=eq key=identity|
                           item sequence start)
                          (|find from-end=false end=nil test=other key=identity|
                           item sequence start test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|find from-end=false end=nil test-not=eql key=identity|
                           item sequence start)
                          (if (eq test-not #'eq)
                              (|find from-end=false end=nil test-not=eq key=identity|
                               item sequence start)
                              (|find from-end=false end=nil test-not=other key=identity|
                               item sequence start test-not)))
                      (|find from-end=false end=nil test=eql key=identity|
                       item sequence start)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function find-if

;;; We tried using some macrology here in order to decrease
;;; the amount of code duplication, but the amount of code 
;;; saved wasn't that great, and the macro code became
;;; incomprehensible instead.

;;; For the versions on lists, we distinguish between 
;;; three different characteristics: 
;;;
;;;   * whether from-end has been given or not
;;;
;;;   * whether the end is the end of the list or not
;;;
;;;   * whether there is a key function or not
;;;
;;; When from-end was not given, we stop iteration as soon
;;; as we find an element that satisfies the test.  When 
;;; from-end was given, we keep going until the end, and
;;; when an element is found that satisifies the test, it
;;; is saved in a variable.  The value of that variable
;;; is then returned at the end.  This method avoids consing
;;; and using up stack space proportional to the length of the
;;; list, but it is costly if the predicate is costly to apply.
;;;
;;; When the end is the end of the list, we avoid a counter
;;; in the loop that checks when the end has been reached.
;;;
;;; When there is no key function, we avoid funcalling the 
;;; key=identity function. 

(defun |find-if-list from-end=false end=nil identity|
    (predicate list start)
  (loop for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate element)
          return element
	finally (tail-must-be-proper-list 'find-if list remaining)))

(defun |find-if-list from-end=false end=nil key|
    (predicate list start key)
  (loop for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          return element
	finally (tail-must-be-proper-list 'find-if list remaining)))

(defun |find-if-list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate element)
          return element
	finally (tail-must-be-proper-list-with-end
		     'find-if list remaining end index)))

(defun |find-if-list from-end=false end=other key|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          return element
	finally (tail-must-be-proper-list-with-end
		     'find-if list remaining end index)))

(defun |find-if-list from-end=true end=nil identity|
    (predicate list start)
  (loop with value = nil
        for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate element)
          do (setf value element)
        finally (tail-must-be-proper-list 'find-if list remaining)
		(return value)))

(defun |find-if-list from-end=true end=nil key|
    (predicate list start key)
  (loop with value = nil
        for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          do (setf value element)
        finally (tail-must-be-proper-list 'find-if list remaining)
		(return value)))
  
(defun |find-if-list from-end=true end=other key=identity|
    (predicate list start end)
  (loop with value = nil
        for index from start
	for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate element)
          do (setf value element)
        finally (tail-must-be-proper-list-with-end
		     'find-if list remaining end index)
		(return value)))

(defun |find-if-list from-end=true end=other key|
    (predicate list start end key)
  (loop with value = nil
        for index from start
	for remaining = (skip-to-start 'find-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          do (setf value element)
        finally (tail-must-be-proper-list-with-end
		     'find-if list remaining end index)
		(return value)))
  
;;; For the versions on lists, we distinguish between 
;;; two different characteristics: 
;;; 
;;;   * whether from-end has been given or not
;;;
;;;   * whether there is a key function or not
;;;
;;; We do not need to distinguish between when an explic
;;; end has been given, and when it has not been given, 
;;; because the loop looks the same anyway; it is just the 
;;; incices of the loop that will change. 
;;;
;;; When from-end has been given, we loop from higher indices 
;;; to lower, otherwise from lower to higher.
;;;
;;; When there is no key function, we avoid a funcall of
;;; key=identity, just as with lists. 

(defun |find-if-vector from-end=false key=identity|
    (predicate vector start end)
  (loop for index from start below (min end (length vector))
        when (funcall predicate (aref vector index))
          return (aref vector index)))

(defun |find-if-vector from-end=false key=other|
    (predicate vector start end key)
  (loop for index from start below (min end (length vector))
        when (funcall predicate (funcall key (aref vector index)))
          return (aref vector index)))

(defun |find-if-vector from-end=true identity|
    (predicate vector start end)
  (loop for index downfrom (1- (min end (length vector))) to start
        when (funcall predicate (aref vector index))
          return (aref vector index)))

(defun |find-if-vector from-end=true key=other|
    (predicate vector start end key)
  (loop for index downfrom (1- (min end (length vector))) to start
        when (funcall predicate (funcall key (aref vector index)))
          return (aref vector index)))

;;; The compiler macro is trying to detect situations where either no
;;; keyword arguments were given, or only constant keyword arguments
;;; were given, so that one of several special versions can be used.
;;; Those special versions will have to check what type of sequence it
;;; is (bacause that is something the compiler macro cannot do), and
;;; then invoke one of the special versions defined above.  On the
;;; other hand, these functions will likely be inlined so that type
;;; inferencing can determine which type of sequence it is at compile
;;; time.

(defun |find-if from-end=false end=nil identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start (length sequence))
       (|find-if-vector from-end=false key=identity|
        predicate sequence start (length sequence)))
    (list
       (|find-if-list from-end=false end=nil identity|
        predicate sequence start))))

(defun |find-if from-end=false end=nil key| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start (length sequence))
       (|find-if-vector from-end=false key=other|
        predicate sequence start (length sequence) key))
    (list
       (|find-if-list from-end=false end=nil key|
        predicate sequence start key))))

(defun |find-if from-end=false end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start end)
       (|find-if-vector from-end=false key=identity|
        predicate sequence start end))
    (list
       (|find-if-list from-end=false end=other key=identity|
        predicate sequence start end))))

(defun |find-if from-end=false end=other key| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start end)
       (|find-if-vector from-end=false key=other|
        predicate sequence start end key))
    (list
       (|find-if-list from-end=false end=other key|
        predicate sequence start end key))))

(defun |find-if from-end=true end=nil identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start (length sequence))
       (|find-if-vector from-end=true identity|
        predicate sequence start (length sequence)))
    (list
       (|find-if-list from-end=true end=nil identity|
        predicate sequence start))))

(defun |find-if from-end=true end=nil key| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start (length sequence))
       (|find-if-vector from-end=true key=other|
        predicate sequence start (length sequence) key))
    (list
       (|find-if-list from-end=true end=nil key|
        predicate sequence start key))))

(defun |find-if from-end=true end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start end)
       (|find-if-vector from-end=true identity|
        predicate sequence start end))
    (list
       (|find-if-list from-end=true end=other key=identity|
        predicate sequence start end))))

(defun |find-if from-end=true end=other key| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if sequence start end)
       (|find-if-vector from-end=true key=other|
        predicate sequence start end key))
    (list
       (|find-if-list from-end=true end=other key|
        predicate sequence start end key))))

;;; This is the main function.  It first checks what type of
;;; sequence it is.  If it is a vector it then distinquishes 
;;; between 4 cases according to whether FROM-END and a KEY
;;; function was given.  If it is a list, it distinguishes
;;; between 8 cases according to whether FROM-END, a KEY 
;;; function, and an explicit END was given. 
;;;
;;; It is expected that this function will not be used very 
;;; often.  In most cases, the compiler macro will be used 
;;; instead. 
(defun find-if (predicate sequence
                &key
                (from-end nil)
                (start 0)
                (end nil)
                (key nil))
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'find-if
	   :datum start
	   :expected-type '(integer 0)))
  (if from-end
      (if key
          (if end
              (|find-if from-end=true end=other key|
               predicate sequence start end key)
              (|find-if from-end=true end=nil key|
               predicate sequence start key))
          (if end
              (|find-if from-end=true end=other key=identity|
               predicate sequence start end)
              (|find-if from-end=true end=nil identity|
               predicate sequence start)))
      (if key
          (if end
              (|find-if from-end=false end=other key|
               predicate sequence start end key)
              (|find-if from-end=false end=nil key|
               predicate sequence start key))
          (if end
              (|find-if from-end=false end=other key=identity|
               predicate sequence start end)
              (|find-if from-end=false end=nil identity|
               predicate sequence start)))))

(define-compiler-macro find-if (&whole form &rest args)
  (handler-case 
      (destructuring-bind (predicate sequence
                           &key
                           (from-end nil from-end-p)
                           (start 0 startp)
                           (end nil endp)
                           (key nil keyp))
          args
        (declare (ignore start))
        (let ((bindings (make-bindings (cddr args))))
          `(let ((start 0))
             ;; start must have a value in case no :start keyword
             ;; argument was given.  On the other hand, if a :start
             ;; keyword argument WAS given, then this variable will
             ;; be shadowed by the let bindings below, and in that
             ;; case, this variable is not used, which is why we
             ;; declare it ignorable. 
             (declare (ignorable start))
             (let ((predicate ,predicate)
                   (sequence ,sequence)
                   ,@bindings)
               ;; Just make every variable ignorable in
               ;; case there are gensyms among them.
               (declare (ignorable ,@(mapcar #'car bindings)))
               ,(if (and endp (not (null end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if from-end=true end=other key|
                                  predicate sequence start end key)
                                `(if from-end
                                     (|find-if from-end=true end=other key|
                                      predicate sequence start end key)
                                     (|find-if from-end=false end=other key|
                                      predicate sequence start end key)))
                            `(|find-if from-end=false end=other key|
                              predicate sequence start end key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if from-end=true end=other key=identity|
                                  predicate sequence start end)
                                `(if from-end
                                     (|find-if from-end=true end=other key=identity|
                                      predicate sequence start end)
                                     (|find-if from-end=false end=other key=identity|
                                      predicate sequence start end)))
                            `(|find-if from-end=false end=other key=identity|
                              predicate sequence start end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if from-end=true end=nil key|
                                  predicate sequence start key)
                                `(if from-end
                                     (|find-if from-end=true end=nil key|
                                      predicate sequence start key)
                                     (|find-if from-end=false end=nil key|
                                      predicate sequence start key)))
                            `(|find-if from-end=false end=nil key|
                              predicate sequence start key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if from-end=true end=nil identity|
                                  predicate sequence start)
                                `(if from-end
                                     (|find-if from-end=true end=nil identity|
                                      predicate sequence start)
                                     (|find-if from-end=false end=nil identity|
                                      predicate sequence start)))
                            `(|find-if from-end=false end=nil identity|
                              predicate sequence start))))))))
    (error () form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function find-if-not

;;; We tried using some macrology here in order to decrease
;;; the amount of code duplication, but the amount of code 
;;; saved wasn't that great, and the macro code became
;;; incomprehensible instead.

;;; For the versions on lists, we distinguish between 
;;; three different characteristics: 
;;;
;;;   * whether from-end has been given or not
;;;
;;;   * whether the end is the end of the list or not
;;;
;;;   * whether there is a key function or not
;;;
;;; When from-end was not given, we stop iteration as soon
;;; as we find an element that satisfies the test.  When 
;;; from-end was given, we keep going until the end, and
;;; when an element is found that satisifies the test, it
;;; is saved in a variable.  The value of that variable
;;; is then returned at the end.  This method avoids consing
;;; and using up stack space proportional to the length of the
;;; list, but it is costly if the predicate is costly to apply.
;;;
;;; When the end is the end of the list, we avoid a counter
;;; in the loop that checks when the end has been reached.
;;;
;;; When there is no key function, we avoid funcalling the 
;;; key=identity function. 

(defun |find-if-not-list from-end=false end=nil identity|
    (predicate list start)
  (loop for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate element)
          return element
	finally (tail-must-be-proper-list 'find-if-not list remaining)))

(defun |find-if-not-list from-end=false end=nil key|
    (predicate list start key)
  (loop for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          return element
	finally (tail-must-be-proper-list 'find-if-not list remaining)))

(defun |find-if-not-list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate element)
          return element
	finally (tail-must-be-proper-list-with-end
		     'find-if-not list remaining end index)))

(defun |find-if-not-list from-end=false end=other key|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          return element
	finally (tail-must-be-proper-list-with-end
		     'find-if-not list remaining end index)))

(defun |find-if-not-list from-end=true end=nil identity|
    (predicate list start)
  (loop with value = nil
        for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate element)
          do (setf value element)
        finally (return value)))

(defun |find-if-not-list from-end=true end=nil key|
    (predicate list start key)
  (loop with value = nil
        for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          do (setf value element)
        finally (return value)))
  
(defun |find-if-not-list from-end=true end=other key=identity|
    (predicate list start end)
  (loop with value = nil
        for index from start
	for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate element)
          do (setf value element)
        finally (return value)))

(defun |find-if-not-list from-end=true end=other key|
    (predicate list start end key)
  (loop with value = nil
        for index from start
        for remaining = (skip-to-start 'find-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        repeat (- end start)
        unless (funcall predicate (funcall key element))
          do (setf value element)
        finally (return value)))
  
;;; For the versions on lists, we distinguish between 
;;; two different characteristics: 
;;; 
;;;   * whether from-end has been given or not
;;;
;;;   * whether there is a key function or not
;;;
;;; We do not need to distinguish between when an explic
;;; end has been given, and when it has not been given, 
;;; because the loop looks the same anyway; it is just the 
;;; incices of the loop that will change. 
;;;
;;; When from-end has been given, we loop from higher indices 
;;; to lower, otherwise from lower to higher.
;;;
;;; When there is no key function, we avoid a funcall of
;;; key=identity, just as with lists. 

(defun |find-if-not-vector from-end=false key=identity|
    (predicate vector start end)
  (loop for index from start below (min end (length vector))
        unless (funcall predicate (aref vector index))
          return (aref vector index)))

(defun |find-if-not-vector from-end=false key=other|
    (predicate vector start end key)
  (loop for index from start below (min end (length vector))
        unless (funcall predicate (funcall key (aref vector index)))
          return (aref vector index)))

(defun |find-if-not-vector from-end=true identity|
    (predicate vector start end)
  (loop for index downfrom (1- (min end (length vector))) to start
        unless (funcall predicate (aref vector index))
          return (aref vector index)))

(defun |find-if-not-vector from-end=true key=other|
    (predicate vector start end key)
  (loop for index downfrom (1- (min end (length vector))) to start
        unless (funcall predicate (funcall key (aref vector index)))
          return (aref vector index)))

;;; The compiler macro is trying to detect situations where either no
;;; keyword arguments were given, or only constant keyword arguments
;;; were given, so that one of several special versions can be used.
;;; Those special versions will have to check what type of sequence it
;;; is (bacause that is something the compiler macro cannot do), and
;;; then invoke one of the special versions defined above.  On the
;;; other hand, these functions will likely be inlined so that type
;;; inferencing can determine which type of sequence it is at compile
;;; time.

(defun |find-if-not from-end=false end=nil identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start (length sequence))
       (|find-if-not-vector from-end=false key=identity|
        predicate sequence start (length sequence)))
    (list
       (|find-if-not-list from-end=false end=nil identity|
        predicate sequence start))))

(defun |find-if-not from-end=false end=nil key| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start (length sequence))
       (|find-if-not-vector from-end=false key=other|
        predicate sequence start (length sequence) key))
    (list
       (|find-if-not-list from-end=false end=nil key|
        predicate sequence start key))))

(defun |find-if-not from-end=false end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start end)
       (|find-if-not-vector from-end=false key=identity|
        predicate sequence start end))
    (list
       (|find-if-not-list from-end=false end=other key=identity|
        predicate sequence start end))))

(defun |find-if-not from-end=false end=other key| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start end)
       (|find-if-not-vector from-end=false key=other|
        predicate sequence start end key))
    (list
       (|find-if-not-list from-end=false end=other key|
        predicate sequence start end key))))

(defun |find-if-not from-end=true end=nil identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start (length sequence))
       (|find-if-not-vector from-end=true identity|
        predicate sequence start (length sequence)))
    (list
       (|find-if-not-list from-end=true end=nil identity|
        predicate sequence start))))

(defun |find-if-not from-end=true end=nil key| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start (length sequence))
       (|find-if-not-vector from-end=true key=other|
        predicate sequence start (length sequence) key))
    (list
       (|find-if-not-list from-end=true end=nil key|
        predicate sequence start key))))

(defun |find-if-not from-end=true end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start end)
       (|find-if-not-vector from-end=true identity|
        predicate sequence start end))
    (list
       (|find-if-not-list from-end=true end=other key=identity|
        predicate sequence start end))))

(defun |find-if-not from-end=true end=other key| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'find-if-not sequence start end)
       (|find-if-not-vector from-end=true key=other|
        predicate sequence start end key))
    (list
       (|find-if-not-list from-end=true end=other key|
        predicate sequence start end key))))

;;; This is the main function.  It first checks what type of
;;; sequence it is.  If it is a vector it then distinquishes 
;;; between 4 cases according to whether FROM-END and a KEY
;;; function was given.  If it is a list, it distinguishes
;;; between 8 cases according to whether FROM-END, a KEY 
;;; function, and an explicit END was given. 
;;;
;;; It is expected that this function will not be used very 
;;; often.  In most cases, the compiler macro will be used 
;;; instead. 
(defun find-if-not (predicate sequence
		    &key
		    (from-end nil)
		    (start 0)
		    (end nil)
		    (key nil))
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'find-if-not
	   :datum start
	   :expected-type '(integer 0)))
  (if from-end
      (if key
          (if end
              (|find-if-not from-end=true end=other key|
               predicate sequence start end key)
              (|find-if-not from-end=true end=nil key|
               predicate sequence start key))
          (if end
              (|find-if-not from-end=true end=other key=identity|
               predicate sequence start end)
              (|find-if-not from-end=true end=nil identity|
               predicate sequence start)))
      (if key
          (if end
              (|find-if-not from-end=false end=other key|
               predicate sequence start end key)
              (|find-if-not from-end=false end=nil key|
               predicate sequence start key))
          (if end
              (|find-if-not from-end=false end=other key=identity|
               predicate sequence start end)
              (|find-if-not from-end=false end=nil identity|
               predicate sequence start)))))

(define-compiler-macro find-if-not (&whole form &rest args)
  (handler-case 
      (destructuring-bind (predicate sequence
                           &key
                           (from-end nil from-end-p)
                           (start 0 startp)
                           (end nil endp)
                           (key nil keyp))
          args
        (declare (ignore start))
        (let ((bindings (make-bindings (cddr args))))
          `(let ((start 0))
             ;; start must have a value in case no :start keyword
             ;; argument was given.  On the other hand, if a :start
             ;; keyword argument WAS given, then this variable will
             ;; be shadowed by the let bindings below, and in that
             ;; case, this variable is not used, which is why we
             ;; declare it ignorable. 
             (declare (ignorable start))
             (let ((predicate ,predicate)
                   (sequence ,sequence)
                   ,@bindings)
               ;; Just make every variable ignorable in
               ;; case there are gensyms among them.
               (declare (ignorable ,@(mapcar #'car bindings)))
               ,(if (and endp (not (null end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if-not from-end=true end=other key|
                                  predicate sequence start end key)
                                `(if from-end
                                     (|find-if-not from-end=true end=other key|
                                      predicate sequence start end key)
                                     (|find-if-not from-end=false end=other key|
                                      predicate sequence start end key)))
                            `(|find-if-not from-end=false end=other key|
                              predicate sequence start end key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if-not from-end=true end=other key=identity|
                                  predicate sequence start end)
                                `(if from-end
                                     (|find-if-not from-end=true end=other key=identity|
                                      predicate sequence start end)
                                     (|find-if-not from-end=false end=other key=identity|
                                      predicate sequence start end)))
                            `(|find-if-not from-end=false end=other key=identity|
                              predicate sequence start end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if-not from-end=true end=nil key|
                                  predicate sequence start key)
                                `(if from-end
                                     (|find-if-not from-end=true end=nil key|
                                      predicate sequence start key)
                                     (|find-if-not from-end=false end=nil key|
                                      predicate sequence start key)))
                            `(|find-if-not from-end=false end=nil key|
                              predicate sequence start key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|find-if-not from-end=true end=nil identity|
                                  predicate sequence start)
                                `(if from-end
                                     (|find-if-not from-end=true end=nil identity|
                                      predicate sequence start)
                                     (|find-if-not from-end=false end=nil identity|
                                      predicate sequence start)))
                            `(|find-if-not from-end=false end=nil identity|
                              predicate sequence start))))))))
    (error () form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function position

(defun |position seq-type=list from-end=false end=nil test=eq key=identity|
    (item list start)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eq item element)
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test=eq key=other|
    (item list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eq item (funcall key element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=eq key=identity|
    (item list start)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eq item element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=eq key=other|
    (item list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eq item (funcall key element)))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test=eql key=identity|
    (item list start)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eql item element)
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test=eql key=other|
    (item list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eql item (funcall key element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=eql key=identity|
    (item list start)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eql item element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=eql key=other|
    (item list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eql item (funcall key element)))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil-test key=identity|
    (item list start test)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (funcall test item element)
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil-test key=other|
    (item list start test key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (funcall test item (funcall key element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=other key=identity|
    (item list start test)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (funcall test item element))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=nil test-not=other key=other|
    (item list start test key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (funcall test item (funcall key element)))
          return index
	finally (tail-must-be-proper-list 'position list remaining)))

(defun |position seq-type=list from-end=false end=other test=eq key=identity|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eq item element)
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test=eq key=other|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eq item (funcall key element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=eq key=identity|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eq item element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=eq key=other|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eq item (funcall key element)))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test=eql key=identity|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eql item element)
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test=eql key=other|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eql item (funcall key element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=eql key=identity|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eql item element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=eql key=other|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eql item (funcall key element)))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other-test key=identity|
    (item list start end test)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall test item element)
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other-test key=other|
    (item list start end test key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall test item (funcall key element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=other key=identity|
    (item list start end test)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (funcall test item element))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=false end=other test-not=other key=other|
    (item list start end test key)
  (loop for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (funcall test item (funcall key element)))
          return index
	finally (tail-must-be-proper-list-with-end 'position list remaining end index)))

(defun |position seq-type=list from-end=true end=nil test=eq key=identity|
    (item list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eq item element)
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test=eq key=other|
    (item list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eq item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=eq key=identity|
    (item list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eq item element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=eq key=other|
    (item list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eq item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test=eql key=identity|
    (item list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eql item element)
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test=eql key=other|
    (item list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (eql item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=eql key=identity|
    (item list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eql item element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=eql key=other|
    (item list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (eql item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil-test key=identity|
    (item list start test)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (funcall test item element)
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil-test key=other|
    (item list start test key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (funcall test item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=other key=identity|
    (item list start test)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (funcall test item element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=nil test-not=other key=other|
    (item list start test key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        
        when (not (funcall test item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position seq-type=list from-end=true end=other test=eq key=identity|
    (item list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eq item element)
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test=eq key=other|
    (item list start end key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eq item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=eq key=identity|
    (item list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eq item element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=eq key=other|
    (item list start end key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eq item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test=eql key=identity|
    (item list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eql item element)
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test=eql key=other|
    (item list start end key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (eql item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=eql key=identity|
    (item list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eql item element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=eql key=other|
    (item list start end key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (eql item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other-test key=identity|
    (item list start end test)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall test item element)
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other-test key=other|
    (item list start end test key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall test item (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=other key=identity|
    (item list start end test)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (funcall test item element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=list from-end=true end=other test-not=other key=other|
    (item list start end test key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (not (funcall test item (funcall key element)))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end index)
		(return result)))

(defun |position seq-type=vector from-end=false test=eq key=identity|
    (item vector start end)
  (loop for index from start below end
        when (eq item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=false test=eq key=other|
    (item vector start end key)
  (loop for index from start below end
        when (eq item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=eq key=identity|
    (item vector start end)
  (loop for index from start below end
        when (not (eq item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=eq key=other|
    (item vector start end key)
  (loop for index from start below end
        when (not (eq item (funcall key (aref vector index))))
          return index))

(defun |position seq-type=vector from-end=false test=eql key=identity|
    (item vector start end)
  (loop for index from start below end
        when (eql item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=false test=eql key=other|
    (item vector start end key)
  (loop for index from start below end
        when (eql item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=eql key=identity|
    (item vector start end)
  (loop for index from start below end
        when (not (eql item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=eql key=other|
    (item vector start end key)
  (loop for index from start below end
        when (not (eql item (funcall key (aref vector index))))
          return index))

(defun |position seq-type=vector from-end=false-test key=identity|
    (item vector start end test)
  (loop for index from start below end
        when (funcall test item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=false-test key=other|
    (item vector start end test key)
  (loop for index from start below end
        when (funcall test item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=other key=identity|
    (item vector start end test)
  (loop for index from start below end
        when (not (funcall test item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=false test-not=other key=other|
    (item vector start end test key)
  (loop for index from start below end
        when (not (funcall test item (funcall key (aref vector index))))
          return index))

(defun |position seq-type=vector from-end=true test=eq key=identity|
    (item vector start end)
  (loop for index downfrom (1- end) to start
        when (eq item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=true test=eq key=other|
    (item vector start end key)
  (loop for index downfrom (1- end) to start
        when (eq item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=eq key=identity|
    (item vector start end)
  (loop for index downfrom (1- end) to start
        when (not (eq item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=eq key=other|
    (item vector start end key)
  (loop for index downfrom (1- end) to start
        when (not (eq item (funcall key (aref vector index))))
          return index))

(defun |position seq-type=vector from-end=true test=eql key=identity|
    (item vector start end)
  (loop for index downfrom (1- end) to start
        when (eql item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=true test=eql key=other|
    (item vector start end key)
  (loop for index downfrom (1- end) to start
        when (eql item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=eql key=identity|
    (item vector start end)
  (loop for index downfrom (1- end) to start
        when (not (eql item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=eql key=other|
    (item vector start end key)
  (loop for index downfrom (1- end) to start
        when (not (eql item (funcall key (aref vector index))))
          return index))

(defun |position seq-type=vector from-end=true-test key=identity|
    (item vector start end test)
  (loop for index downfrom (1- end) to start
        when (funcall test item (aref vector index))
          return index))

(defun |position seq-type=vector from-end=true-test key=other|
    (item vector start end test key)
  (loop for index downfrom (1- end) to start
        when (funcall test item (funcall key (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=other key=identity|
    (item vector start end test)
  (loop for index downfrom (1- end) to start
        when (not (funcall test item (aref vector index)))
          return index))

(defun |position seq-type=vector from-end=true test-not=other key=other|
    (item vector start end test key)
  (loop for index downfrom (1- end) to start
        when (not (funcall test item (funcall key (aref vector index))))
          return index))

(defun |position from-end=false end=nil test=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=false end=nil test=eq key=identity|
        item sequence start))))

(defun |position from-end=false end=nil test=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=false end=nil test=eq key=other|
        item sequence start key))))

(defun |position from-end=false end=nil test-not=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=false end=nil test-not=eq key=identity|
        item sequence start))))

(defun |position from-end=false end=nil test-not=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=false end=nil test-not=eq key=other|
        item sequence start key))))

(defun |position from-end=false end=nil test=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=false end=nil test=eql key=identity|
        item sequence start))))

(defun |position from-end=false end=nil test=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=false end=nil test=eql key=other|
        item sequence start key))))

(defun |position from-end=false end=nil test-not=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=false end=nil test-not=eql key=identity|
        item sequence start))))

(defun |position from-end=false end=nil test-not=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=false end=nil test-not=eql key=other|
        item sequence start key))))

(defun |position from-end=false end=nil-test key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false-test key=identity|
        item sequence start (length sequence) test))
    (list
       (|position seq-type=list from-end=false end=nil-test key=identity|
        item sequence start test))))

(defun |position from-end=false end=nil-test key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false-test key=other|
        item sequence start (length sequence) test key))
    (list
       (|position seq-type=list from-end=false end=nil-test key=other|
        item sequence start test key))))

(defun |position from-end=false end=nil test-not=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|position seq-type=list from-end=false end=nil test-not=other key=identity|
        item sequence start test))))

(defun |position from-end=false end=nil test-not=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test-not=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|position seq-type=list from-end=false end=nil test-not=other key=other|
        item sequence start test key))))

(defun |position from-end=false end=other test=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=false test=eq key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=false end=other test=eq key=identity|
        item sequence start end))))

(defun |position from-end=false end=other test=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test=eq key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=false end=other test=eq key=other|
        item sequence start end key))))

(defun |position from-end=false end=other test-not=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=eq key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=false end=other test-not=eq key=identity|
        item sequence start end))))

(defun |position from-end=false end=other test-not=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=eq key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=false end=other test-not=eq key=other|
        item sequence start end key))))

(defun |position from-end=false end=other test=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test=eql key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=false end=other test=eql key=identity|
        item sequence start end))))

(defun |position from-end=false end=other test=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test=eql key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=false end=other test=eql key=other|
        item sequence start end key))))

(defun |position from-end=false end=other test-not=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=eql key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=false end=other test-not=eql key=identity|
        item sequence start end))))

(defun |position from-end=false end=other test-not=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=eql key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=false end=other test-not=eql key=other|
        item sequence start end key))))

(defun |position from-end=false end=other-test key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false-test key=identity|
        item sequence start end test))
    (list
       (|position seq-type=list from-end=false end=other-test key=identity|
        item sequence start end test))))

(defun |position from-end=false end=other-test key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false-test key=other|
        item sequence start end test key))
    (list
       (|position seq-type=list from-end=false end=other-test key=other|
        item sequence start end test key))))

(defun |position from-end=false end=other test-not=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=other key=identity|
        item sequence start end test))
    (list
       (|position seq-type=list from-end=false end=other test-not=other key=identity|
        item sequence start end test))))

(defun |position from-end=false end=other test-not=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=false test-not=other key=other|
        item sequence start end test key))
    (list
       (|position seq-type=list from-end=false end=other test-not=other key=other|
        item sequence start end test key))))

(defun |position from-end=true end=nil test=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=true end=nil test=eq key=identity|
        item sequence start))))

(defun |position from-end=true end=nil test=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=true end=nil test=eq key=other|
        item sequence start key))))

(defun |position from-end=true end=nil test-not=eq key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=eq key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=true end=nil test-not=eq key=identity|
        item sequence start))))

(defun |position from-end=true end=nil test-not=eq key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=eq key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=true end=nil test-not=eq key=other|
        item sequence start key))))

(defun |position from-end=true end=nil test=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=true end=nil test=eql key=identity|
        item sequence start))))

(defun |position from-end=true end=nil test=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=true end=nil test=eql key=other|
        item sequence start key))))

(defun |position from-end=true end=nil test-not=eql key=identity|
    (item sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=eql key=identity|
        item sequence start (length sequence)))
    (list
       (|position seq-type=list from-end=true end=nil test-not=eql key=identity|
        item sequence start))))

(defun |position from-end=true end=nil test-not=eql key=other|
    (item sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=eql key=other|
        item sequence start (length sequence) key))
    (list
       (|position seq-type=list from-end=true end=nil test-not=eql key=other|
        item sequence start key))))

(defun |position from-end=true end=nil-test key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true-test key=identity|
        item sequence start (length sequence) test))
    (list
       (|position seq-type=list from-end=true end=nil-test key=identity|
        item sequence start test))))

(defun |position from-end=true end=nil-test key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true-test key=other|
        item sequence start (length sequence) test key))
    (list
       (|position seq-type=list from-end=true end=nil-test key=other|
        item sequence start test key))))

(defun |position from-end=true end=nil test-not=other key=identity|
    (item sequence start test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=other key=identity|
        item sequence start (length sequence) test))
    (list
       (|position seq-type=list from-end=true end=nil test-not=other key=identity|
        item sequence start test))))

(defun |position from-end=true end=nil test-not=other key=other|
    (item sequence start test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start (length sequence))
       (|position seq-type=vector from-end=true test-not=other key=other|
        item sequence start (length sequence) test key))
    (list
       (|position seq-type=list from-end=true end=nil test-not=other key=other|
        item sequence start test key))))

(defun |position from-end=true end=other test=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test=eq key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=true end=other test=eq key=identity|
        item sequence start end))))

(defun |position from-end=true end=other test=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test=eq key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=true end=other test=eq key=other|
        item sequence start end key))))

(defun |position from-end=true end=other test-not=eq key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=eq key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=true end=other test-not=eq key=identity|
        item sequence start end))))

(defun |position from-end=true end=other test-not=eq key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=eq key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=true end=other test-not=eq key=other|
        item sequence start end key))))

(defun |position from-end=true end=other test=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test=eql key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=true end=other test=eql key=identity|
        item sequence start end))))

(defun |position from-end=true end=other test=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test=eql key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=true end=other test=eql key=other|
        item sequence start end key))))

(defun |position from-end=true end=other test-not=eql key=identity|
    (item sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=eql key=identity|
        item sequence start end))
    (list
       (|position seq-type=list from-end=true end=other test-not=eql key=identity|
        item sequence start end))))

(defun |position from-end=true end=other test-not=eql key=other|
    (item sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=eql key=other|
        item sequence start end key))
    (list
       (|position seq-type=list from-end=true end=other test-not=eql key=other|
        item sequence start end key))))

(defun |position from-end=true end=other-test key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true-test key=identity|
        item sequence start end test))
    (list
       (|position seq-type=list from-end=true end=other-test key=identity|
        item sequence start end test))))

(defun |position from-end=true end=other-test key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true-test key=other|
        item sequence start end test key))
    (list
       (|position seq-type=list from-end=true end=other-test key=other|
        item sequence start end test key))))

(defun |position from-end=true end=other test-not=other key=identity|
    (item sequence start end test)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=other key=identity|
        item sequence start end test))
    (list
       (|position seq-type=list from-end=true end=other test-not=other key=identity|
        item sequence start end test))))

(defun |position from-end=true end=other test-not=other key=other|
    (item sequence start end test key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position sequence start end)
       (|position seq-type=vector from-end=true test-not=other key=other|
        item sequence start end test key))
    (list
       (|position seq-type=list from-end=true end=other test-not=other key=other|
        item sequence start end test key))))

(defun position (item sequence
             &key
             from-end
             (test nil test-p)
             (test-not nil test-not-p)
             (start 0)
             end
             key)
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'position
	   :datum start
	   :expected-type '(integer 0)))
  (when (and test-p test-not-p)
    (error 'both-test-and-test-not-given
	   :name 'position))
  (if from-end
      (if key
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=true end=other test=eql key=other|
                       item sequence start end key)
                      (if (eq test #'eq)
                          (|position from-end=true end=other test=eq key=other|
                           item sequence start end key)
                          (|position from-end=true end=other-test key=other|
                           item sequence start end test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=true end=other test-not=eql key=other|
                           item sequence start end key)
                          (if (eq test-not #'eq)
                              (|position from-end=true end=other test-not=eq key=other|
                               item sequence start end key)
                              (|position from-end=true end=other test-not=other key=other|
                               item sequence start end test-not key)))
                      (|position from-end=true end=other test=eql key=other|
                       item sequence start end key)))
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=true end=nil test=eql key=other|
                       item sequence start key)
                      (if (eq test #'eq)
                          (|position from-end=true end=nil test=eq key=other|
                           item sequence start key)
                          (|position from-end=true end=nil-test key=other|
                           item sequence start test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=true end=nil test-not=eql key=other|
                           item sequence start key)
                          (if (eq test-not #'eq)
                              (|position from-end=true end=nil test-not=eq key=other|
                               item sequence start key)
                              (|position from-end=true end=nil test-not=other key=other|
                               item sequence start test-not key)))
                      (|position from-end=true end=nil test=eql key=other|
                       item sequence start key))))
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=true end=other test=eql key=identity|
                       item sequence start end)
                      (if (eq test #'eq)
                          (|position from-end=true end=other test=eq key=identity|
                           item sequence start end)
                          (|position from-end=true end=other-test key=identity|
                           item sequence start end test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=true end=other test-not=eql key=identity|
                           item sequence start end)
                          (if (eq test-not #'eq)
                              (|position from-end=true end=other test-not=eq key=identity|
                               item sequence start end)
                              (|position from-end=true end=other test-not=other key=identity|
                               item sequence start end test-not)))
                      (|position from-end=true end=other test=eql key=identity|
                       item sequence start end)))
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=true end=nil test=eql key=identity|
                       item sequence start)
                      (if (eq test #'eq)
                          (|position from-end=true end=nil test=eq key=identity|
                           item sequence start)
                          (|position from-end=true end=nil-test key=identity|
                           item sequence start test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=true end=nil test-not=eql key=identity|
                           item sequence start)
                          (if (eq test-not #'eq)
                              (|position from-end=true end=nil test-not=eq key=identity|
                               item sequence start)
                              (|position from-end=true end=nil test-not=other key=identity|
                               item sequence start test-not)))
                      (|position from-end=true end=nil test=eql key=identity|
                       item sequence start)))))
      (if key
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=false end=other test=eql key=other|
                       item sequence start end key)
                      (if (eq test #'eq)
                          (|position from-end=false end=other test=eq key=other|
                           item sequence start end key)
                          (|position from-end=false end=other-test key=other|
                           item sequence start end test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=false end=other test-not=eql key=other|
                           item sequence start end key)
                          (if (eq test-not #'eq)
                              (|position from-end=false end=other test-not=eq key=other|
                               item sequence start end key)
                              (|position from-end=false end=other test-not=other key=other|
                               item sequence start end test-not key)))
                      (|position from-end=false end=other test=eql key=other|
                       item sequence start end key)))
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=false end=nil test=eql key=other|
                       item sequence start key)
                      (if (eq test #'eq)
                          (|position from-end=false end=nil test=eq key=other|
                           item sequence start key)
                          (|position from-end=false end=nil-test key=other|
                           item sequence start test key)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=false end=nil test-not=eql key=other|
                           item sequence start key)
                          (if (eq test-not #'eq)
                              (|position from-end=false end=nil test-not=eq key=other|
                               item sequence start key)
                              (|position from-end=false end=nil test-not=other key=other|
                               item sequence start test-not key)))
                      (|position from-end=false end=nil test=eql key=other|
                       item sequence start key))))
          (if end
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=false end=other test=eql key=identity|
                       item sequence start end)
                      (if (eq test #'eq)
                          (|position from-end=false end=other test=eq key=identity|
                           item sequence start end)
                          (|position from-end=false end=other-test key=identity|
                           item sequence start end test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=false end=other test-not=eql key=identity|
                           item sequence start end)
                          (if (eq test-not #'eq)
                              (|position from-end=false end=other test-not=eq key=identity|
                               item sequence start end)
                              (|position from-end=false end=other test-not=other key=identity|
                               item sequence start end test-not)))
                      (|position from-end=false end=other test=eql key=identity|
                       item sequence start end)))
              (if test-p
                  (if (eq test #'eql)
                      (|position from-end=false end=nil test=eql key=identity|
                       item sequence start)
                      (if (eq test #'eq)
                          (|position from-end=false end=nil test=eq key=identity|
                           item sequence start)
                          (|position from-end=false end=nil-test key=identity|
                           item sequence start test)))
                  (if test-not-p
                      (if (eq test-not #'eql)
                          (|position from-end=false end=nil test-not=eql key=identity|
                           item sequence start)
                          (if (eq test-not #'eq)
                              (|position from-end=false end=nil test-not=eq key=identity|
                               item sequence start)
                              (|position from-end=false end=nil test-not=other key=identity|
                               item sequence start test-not)))
                      (|position from-end=false end=nil test=eql key=identity|
                       item sequence start)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function position-if

;;; We tried using some macrology here in order to decrease
;;; the amount of code duplication, but the amount of code 
;;; saved wasn't that great, and the macro code became
;;; incomprehensible instead.

;;; For the versions on lists, we distinguish between 
;;; three different characteristics: 
;;;
;;;   * whether from-end has been given or not
;;;
;;;   * whether the end is the end of the list or not
;;;
;;;   * whether there is a key function or not
;;;
;;; When from-end was not given, we stop iteration as soon
;;; as we position an element that satisfies the test.  When 
;;; from-end was given, we keep going until the end, and
;;; when an element is found that satisifies the test, it
;;; is saved in a variable.  The value of that variable
;;; is then returned at the end.  This method avoids consing
;;; and using up stack space proportional to the length of the
;;; list, but it is costly if the predicate is costly to apply.
;;;
;;; When the end is the end of the list, we avoid a counter
;;; in the loop that checks when the end has been reached.
;;;
;;; When there is no key function, we avoid funcalling the 
;;; identity function. 

(defun |position-if seq-type=list from-end=false end=nil key=identity|
    (predicate list start)
  (loop for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate element)
          return index
	finally (tail-must-be-proper-list 'position-if list remaining)))

(defun |position-if seq-type=list from-end=false end=nil key=other|
    (predicate list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          return index
	finally (tail-must-be-proper-list 'position-if list remaining)))

(defun |position-if seq-type=list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate element)
          return index
	finally (tail-must-be-proper-list-with-end
		     'position-if list remaining end index)))

(defun |position-if seq-type=list from-end=false end=other key=other|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          return index
	finally (tail-must-be-proper-list-with-end
		     'position-if list remaining end index)))

(defun |position-if seq-type=list from-end=true end=nil key=identity|
    (predicate list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate element)
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position-if seq-type=list from-end=true end=nil key=other|
    (predicate list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position-if seq-type=list from-end=true end=other key=identity|
    (predicate list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate element)
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end 1000)
		(return result)))

(defun |position-if seq-type=list from-end=true end=other key=other|
    (predicate list start end key)
  (loop with result = nil
        for index from start
        for remaining = (skip-to-start 'position-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        when (funcall predicate (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end 1000)
		(return result)))

;;; For the versions on lists, we distinguish between 
;;; two different characteristics: 
;;; 
;;;   * whether from-end has been given or not
;;;
;;;   * whether there is a key function or not
;;;
;;; We do not need to distinguish between when an explic
;;; end has been given, and when it has not been given, 
;;; because the loop looks the same anyway; it is just the 
;;; incices of the loop that will change. 
;;;
;;; When from-end has been given, we loop from higher indices 
;;; to lower, otherwise from lower to higher.
;;;
;;; When there is no key function, we avoid a funcall of
;;; identity, just as with lists. 

(defun |position-if seq-type=vector from-end=false key=identity|
    (predicate vector start end)
  (loop for index from start below (min end (length vector))
        when (funcall predicate (aref vector index))
          return index))

(defun |position-if seq-type=vector from-end=false key=other|
    (predicate vector start end key)
  (loop for index from start below (min end (length vector))
        when (funcall predicate (funcall key (aref vector index)))
          return index))

(defun |position-if seq-type=vector from-end=true key=identity|
    (predicate vector start end)
  (loop for index downfrom (1- (min end (length vector))) to start
        when (funcall predicate (aref vector index))
          return index))

(defun |position-if seq-type=vector from-end=true key=other|
    (predicate vector start end key)
  (loop for index downfrom (1- (min end (length vector))) to start
        when (funcall predicate (funcall key (aref vector index)))
          return index))

;;; The compiler macro is trying to detect situations where either no
;;; keyword arguments were given, or only constant keyword arguments
;;; were given, so that one of several special versions can be used.
;;; Those special versions will have to check what type of sequence it
;;; is (bacause that is something the compiler macro cannot do), and
;;; then invoke one of the special versions defined above.  On the
;;; other hand, these functions will likely be inlined so that type
;;; inferencing can determine which type of sequence it is at compile
;;; time.

(defun |position-if from-end=false end=nil key=identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start (length sequence))
       (|position-if seq-type=vector from-end=false key=identity|
        predicate sequence start (length sequence)))
    (list
       (|position-if seq-type=list from-end=false end=nil key=identity|
        predicate sequence start))))

(defun |position-if from-end=false end=nil key=other| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start (length sequence))
       (|position-if seq-type=vector from-end=false key=other|
        predicate sequence start (length sequence) key))
    (list
       (|position-if seq-type=list from-end=false end=nil key=other|
        predicate sequence start key))))

(defun |position-if from-end=false end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start end)
       (|position-if seq-type=vector from-end=false key=identity|
        predicate sequence start end))
    (list
       (|position-if seq-type=list from-end=false end=other key=identity|
        predicate sequence start end))))

(defun |position-if from-end=false end=other key=other| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start end)
       (|position-if seq-type=vector from-end=false key=other|
        predicate sequence start end key))
    (list
       (|position-if seq-type=list from-end=false end=other key=other|
        predicate sequence start end key))))

(defun |position-if from-end=true end=nil key=identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start (length sequence))
       (|position-if seq-type=vector from-end=true key=identity|
        predicate sequence start (length sequence)))
    (list
       (|position-if seq-type=list from-end=true end=nil key=identity|
        predicate sequence start))))

(defun |position-if from-end=true end=nil key=other| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start (length sequence))
       (|position-if seq-type=vector from-end=true key=other|
        predicate sequence start (length sequence) key))
    (list
       (|position-if seq-type=list from-end=true end=nil key=other|
        predicate sequence start key))))

(defun |position-if from-end=true end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start end)
       (|position-if seq-type=vector from-end=true key=identity|
        predicate sequence start end))
    (list
       (|position-if seq-type=list from-end=true end=other key=identity|
        predicate sequence start end))))

(defun |position-if from-end=true end=other key=other| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if sequence start end)
       (|position-if seq-type=vector from-end=true key=other|
        predicate sequence start end key))
    (list
       (|position-if seq-type=list from-end=true end=other key=other|
        predicate sequence start end key))))

;;; This is the main function.  It first checks what type of
;;; sequence it is.  If it is a vector it then distinquishes 
;;; between 4 cases according to whether FROM-END and a KEY
;;; function was given.  If it is a list, it distinguishes
;;; between 8 cases according to whether FROM-END, a KEY 
;;; function, and an explicit END was given. 
;;;
;;; It is expected that this function will not be used very 
;;; often.  In most cases, the compiler macro will be used 
;;; instead. 
(defun position-if (predicate sequence
                &key
                (from-end nil)
                (start 0)
                (end nil)
                (key nil))
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'position
	   :datum start
	   :expected-type '(integer 0)))
  (if from-end
      (if key
          (if end
              (|position-if from-end=true end=other key=other|
               predicate sequence start end key)
              (|position-if from-end=true end=nil key=other|
               predicate sequence start key))
          (if end
              (|position-if from-end=true end=other key=identity|
               predicate sequence start end)
              (|position-if from-end=true end=nil key=identity|
               predicate sequence start)))
      (if key
          (if end
              (|position-if from-end=false end=other key=other|
               predicate sequence start end key)
              (|position-if from-end=false end=nil key=other|
               predicate sequence start key))
          (if end
              (|position-if from-end=false end=other key=identity|
               predicate sequence start end)
              (|position-if from-end=false end=nil key=identity|
               predicate sequence start)))))

(define-compiler-macro position-if (&whole form &rest args)
  (handler-case 
      (destructuring-bind (predicate sequence
                           &key
                           (from-end nil from-end-p)
                           (start 0 startp)
                           (end nil endp)
                           (key nil keyp))
          args
        (declare (ignore start))
        (let ((bindings (make-bindings (cddr args))))
          `(let ((start 0))
             ;; start must have a value in case no :start keyword
             ;; argument was given.  On the other hand, if a :start
             ;; keyword argument WAS given, then this variable will
             ;; be shadowed by the let bindings below, and in that
             ;; case, this variable is not used, which is why we
             ;; declare it ignorable. 
             (declare (ignorable start))
             (let ((predicate ,predicate)
                   (sequence ,sequence)
                   ,@bindings)
               ;; Just make every variable ignorable in
               ;; case there are gensyms among them.
               (declare (ignorable ,@(mapcar #'car bindings)))
               ,(if (and endp (not (null end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if from-end=true end=other key=other|
                                  predicate sequence start end key)
                                `(if from-end
                                     (|position-if from-end=true end=other key=other|
                                      predicate sequence start end key)
                                     (|position-if from-end=false end=other key=other|
                                      predicate sequence start end key)))
                            `(|position-if from-end=false end=other key=other|
                              predicate sequence start end key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if from-end=true end=other key=identity|
                                  predicate sequence start end)
                                `(if from-end
                                     (|position-if from-end=true end=other key=identity|
                                      predicate sequence start end)
                                     (|position-if from-end=false end=other key=identity|
                                      predicate sequence start end)))
                            `(|position-if from-end=false end=other key=identity|
                              predicate sequence start end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if from-end=true end=nil key=other|
                                  predicate sequence start key)
                                `(if from-end
                                     (|position-if from-end=true end=nil key=other|
                                      predicate sequence start key)
                                     (|position-if from-end=false end=nil key=other|
                                      predicate sequence start key)))
                            `(|position-if from-end=false end=nil key=other|
                              predicate sequence start key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if from-end=true end=nil key=identity|
                                  predicate sequence start)
                                `(if from-end
                                     (|position-if from-end=true end=nil key=identity|
                                      predicate sequence start)
                                     (|position-if from-end=false end=nil key=identity|
                                      predicate sequence start)))
                            `(|position-if from-end=false end=nil key=identity|
                              predicate sequence start))))))))
    (error () form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function position-if-not

;;; We tried using some macrology here in order to decrease
;;; the amount of code duplication, but the amount of code 
;;; saved wasn't that great, and the macro code became
;;; incomprehensible instead.

;;; For the versions on lists, we distinguish between 
;;; three different characteristics: 
;;;
;;;   * whether from-end has been given or not
;;;
;;;   * whether the end is the end of the list or not
;;;
;;;   * whether there is a key function or not
;;;
;;; When from-end was not given, we stop iteration as soon
;;; as we position an element that satisfies the test.  When 
;;; from-end was given, we keep going until the end, and
;;; when an element is found that satisifies the test, it
;;; is saved in a variable.  The value of that variable
;;; is then returned at the end.  This method avoids consing
;;; and using up stack space proportional to the length of the
;;; list, but it is costly if the predicate is costly to apply.
;;;
;;; When the end is the end of the list, we avoid a counter
;;; in the loop that checks when the end has been reached.
;;;
;;; When there is no key function, we avoid funcalling the 
;;; identity function. 

(defun |position-if-not seq-type=list from-end=false end=nil key=identity|
    (predicate list start)
  (loop for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate element)
          return index
	finally (tail-must-be-proper-list 'position-if-not list remaining)))

(defun |position-if-not seq-type=list from-end=false end=nil key=other|
    (predicate list start key)
  (loop for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          return index
	finally (tail-must-be-proper-list 'position-if-not list remaining)))

(defun |position-if-not seq-type=list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate element)
          return index
	finally (tail-must-be-proper-list-with-end
		     'position-if-not list remaining end index)))

(defun |position-if-not seq-type=list from-end=false end=other key=other|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          return index
	finally (tail-must-be-proper-list-with-end
		     'position-if-not list remaining end index)))

(defun |position-if-not seq-type=list from-end=true end=nil key=identity|
    (predicate list start)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate element)
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))

(defun |position-if-not seq-type=list from-end=true end=nil key=other|
    (predicate list start key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
        unless (funcall predicate (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list 'position list remaining)
		(return result)))
  
(defun |position-if-not seq-type=list from-end=true end=other key=identity|
    (predicate list start end)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        unless (funcall predicate element)
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end 1000)
		(return result)))

(defun |position-if-not seq-type=list from-end=true end=other key=other|
    (predicate list start end key)
  (loop with result = nil
        for index from start
	for remaining = (skip-to-start 'position-if-not list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
        repeat (- end start)
        unless (funcall predicate (funcall key element))
          do (setf result index)
        finally (tail-must-be-proper-list-with-end 'position list remaining end 1000)
		(return result)))
  
;;; For the versions on lists, we distinguish between 
;;; two different characteristics: 
;;; 
;;;   * whether from-end has been given or not
;;;
;;;   * whether there is a key function or not
;;;
;;; We do not need to distinguish between when an explic
;;; end has been given, and when it has not been given, 
;;; because the loop looks the same anyway; it is just the 
;;; incices of the loop that will change. 
;;;
;;; When from-end has been given, we loop from higher indices 
;;; to lower, otherwise from lower to higher.
;;;
;;; When there is no key function, we avoid a funcall of
;;; identity, just as with lists. 

(defun |position-if-not seq-type=vector from-end=false key=identity|
    (predicate vector start end)
  (loop for index from start below (min end (length vector))
        unless (funcall predicate (aref vector index))
          return index))

(defun |position-if-not seq-type=vector from-end=false key=other|
    (predicate vector start end key)
  (loop for index from start below (min end (length vector))
        unless (funcall predicate (funcall key (aref vector index)))
          return index))

(defun |position-if-not seq-type=vector from-end=true key=identity|
    (predicate vector start end)
  (loop for index downfrom (1- (min end (length vector))) to start
        unless (funcall predicate (aref vector index))
          return index))

(defun |position-if-not seq-type=vector from-end=true key=other|
    (predicate vector start end key)
  (loop for index downfrom (1- (min end (length vector))) to start
        unless (funcall predicate (funcall key (aref vector index)))
          return index))

;;; The compiler macro is trying to detect situations where either no
;;; keyword arguments were given, or only constant keyword arguments
;;; were given, so that one of several special versions can be used.
;;; Those special versions will have to check what type of sequence it
;;; is (bacause that is something the compiler macro cannot do), and
;;; then invoke one of the special versions defined above.  On the
;;; other hand, these functions will likely be inlined so that type
;;; inferencing can determine which type of sequence it is at compile
;;; time.

(defun |position-if-not from-end=false end=nil key=identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start (length sequence))
       (|position-if-not seq-type=vector from-end=false key=identity|
        predicate sequence start (length sequence)))
    (list
       (|position-if-not seq-type=list from-end=false end=nil key=identity|
        predicate sequence start))))

(defun |position-if-not from-end=false end=nil key=other| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start (length sequence))
       (|position-if-not seq-type=vector from-end=false key=other|
        predicate sequence start (length sequence) key))
    (list
       (|position-if-not seq-type=list from-end=false end=nil key=other|
        predicate sequence start key))))

(defun |position-if-not from-end=false end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start end)
       (|position-if-not seq-type=vector from-end=false key=identity|
        predicate sequence start end))
    (list
       (|position-if-not seq-type=list from-end=false end=other key=identity|
        predicate sequence start end))))

(defun |position-if-not from-end=false end=other key=other| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start end)
       (|position-if-not seq-type=vector from-end=false key=other|
        predicate sequence start end key))
    (list
       (|position-if-not seq-type=list from-end=false end=other key=other|
        predicate sequence start end key))))

(defun |position-if-not from-end=true end=nil key=identity| (predicate sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start (length sequence))
       (|position-if-not seq-type=vector from-end=true key=identity|
        predicate sequence start (length sequence)))
    (list
       (|position-if-not seq-type=list from-end=true end=nil key=identity|
        predicate sequence start))))

(defun |position-if-not from-end=true end=nil key=other| (predicate sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start (length sequence))
       (|position-if-not seq-type=vector from-end=true key=other|
        predicate sequence start (length sequence) key))
    (list
       (|position-if-not seq-type=list from-end=true end=nil key=other|
        predicate sequence start key))))

(defun |position-if-not from-end=true end=other key=identity| (predicate sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start end)
       (|position-if-not seq-type=vector from-end=true key=identity|
        predicate sequence start end))
    (list
       (|position-if-not seq-type=list from-end=true end=other key=identity|
        predicate sequence start end))))

(defun |position-if-not from-end=true end=other key=other| (predicate sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'position-if-not sequence start end)
       (|position-if-not seq-type=vector from-end=true key=other|
        predicate sequence start end key))
    (list
       (|position-if-not seq-type=list from-end=true end=other key=other|
        predicate sequence start end key))))

;;; This is the main function.  It first checks what type of
;;; sequence it is.  If it is a vector it then distinquishes 
;;; between 4 cases according to whether FROM-END and a KEY
;;; function was given.  If it is a list, it distinguishes
;;; between 8 cases according to whether FROM-END, a KEY 
;;; function, and an explicit END was given. 
;;;
;;; It is expected that this function will not be used very 
;;; often.  In most cases, the compiler macro will be used 
;;; instead. 
(defun position-if-not (predicate sequence
		    &key
		    (from-end nil)
		    (start 0)
		    (end nil)
		    (key nil))
  (when (or (not (integerp start))
	    (minusp start))
    (error 'invalid-start-index-type
	   :name 'position
	   :datum start
	   :expected-type '(integer 0)))
  (if from-end
      (if key
          (if end
              (|position-if-not from-end=true end=other key=other|
               predicate sequence start end key)
              (|position-if-not from-end=true end=nil key=other|
               predicate sequence start key))
          (if end
              (|position-if-not from-end=true end=other key=identity|
               predicate sequence start end)
              (|position-if-not from-end=true end=nil key=identity|
               predicate sequence start)))
      (if key
          (if end
              (|position-if-not from-end=false end=other key=other|
               predicate sequence start end key)
              (|position-if-not from-end=false end=nil key=other|
               predicate sequence start key))
          (if end
              (|position-if-not from-end=false end=other key=identity|
               predicate sequence start end)
              (|position-if-not from-end=false end=nil key=identity|
               predicate sequence start)))))

(define-compiler-macro position-if-not (&whole form &rest args)
  (handler-case 
      (destructuring-bind (predicate sequence
                           &key
                           (from-end nil from-end-p)
                           (start 0 startp)
                           (end nil endp)
                           (key nil keyp))
          args
        (declare (ignore start))
        (let ((bindings (make-bindings (cddr args))))
          `(let ((start 0))
             ;; start must have a value in case no :start keyword
             ;; argument was given.  On the other hand, if a :start
             ;; keyword argument WAS given, then this variable will
             ;; be shadowed by the let bindings below, and in that
             ;; case, this variable is not used, which is why we
             ;; declare it ignorable. 
             (declare (ignorable start))
             (let ((predicate ,predicate)
                   (sequence ,sequence)
                   ,@bindings)
               ;; Just make every variable ignorable in
               ;; case there are gensyms among them.
               (declare (ignorable ,@(mapcar #'car bindings)))
               ,(if (and endp (not (null end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if-not from-end=true end=other key=other|
                                  predicate sequence start end key)
                                `(if from-end
                                     (|position-if-not from-end=true end=other key=other|
                                      predicate sequence start end key)
                                     (|position-if-not from-end=false end=other key=other|
                                      predicate sequence start end key)))
                            `(|position-if-not from-end=false end=other key=other|
                              predicate sequence start end key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if-not from-end=true end=other key=identity|
                                  predicate sequence start end)
                                `(if from-end
                                     (|position-if-not from-end=true end=other key=identity|
                                      predicate sequence start end)
                                     (|position-if-not from-end=false end=other key=identity|
                                      predicate sequence start end)))
                            `(|position-if-not from-end=false end=other key=identity|
                              predicate sequence start end)))
                    (if (and keyp (not (null key)))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if-not from-end=true end=nil key=other|
                                  predicate sequence start key)
                                `(if from-end
                                     (|position-if-not from-end=true end=nil key=other|
                                      predicate sequence start key)
                                     (|position-if-not from-end=false end=nil key=other|
                                      predicate sequence start key)))
                            `(|position-if-not from-end=false end=nil key=other|
                              predicate sequence start key))
                        (if from-end-p
                            (if (eq from-end t)
                                `(|position-if-not from-end=true end=nil key=identity|
                                  predicate sequence start)
                                `(if from-end
                                     (|position-if-not from-end=true end=nil key=identity|
                                      predicate sequence start)
                                     (|position-if-not from-end=false end=nil key=identity|
                                      predicate sequence start)))
                            `(|position-if-not from-end=false end=nil key=identity|
                              predicate sequence start))))))))
    (error () form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function length

;;; Compute the length of a proper list, or signal an error if
;;; the list is not a proper list.
(defun length-of-proper-list (name list)
  (loop for remainder = list then (cdr remainder)
        for length from 0
        while (consp remainder)
        finally (if (null remainder)
		    (return length)
		    (error 'must-be-proper-list
			   :name name
			   :datum list))))

(defun length-of-proper-sequence (name sequence)
  (if (vectorp sequence)
      (if (array-has-fill-pointer-p sequence)
           (fill-pointer sequence)
           (array-dimension sequence 0))
      (length-of-proper-list name sequence)))

(defun length (sequence)
  (length-of-proper-sequence 'length sequence))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Accessor subseq

(defun subseq (sequence start &optional end)
  (if (listp sequence)
      (let ((list sequence))
	(loop repeat start
	      do (setf list (cdr list)))
	(if end
	    (let* ((end-start (- end start))
		   (result (loop for element in list
				 until (zerop end-start)
				 collect element
				 do (decf end-start))))
	      (if (plusp end-start)
		  (error 'invalid-end-index
			 :datum end
			 :expected-type `(integer 0 ,(- end end-start))
			 :in-sequence sequence)
		  result))
	    (loop for element in list
		  collect element)))
      (progn (when (null end)
	       (setf end (length sequence)))
	     (when (> end (length sequence))
	       (error  'invalid-end-index
		       :datum end
		       :expected-type `(integer 0 ,(length sequence))
		       :in-sequence sequence))
	     (let ((result (make-array (- end start)
				       :element-type (array-element-type sequence))))
	       (loop for i from start below end
		     do (setf (aref result (- i start))
			      (aref sequence i)))
	       result))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function reduce

(defun |reduce seq-type=list from-end=false end=nil key=identity-no-initial|
    (function list start)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) (funcall function))
          ((null (cdr remaining)) (car remaining))
          (t (loop with value = (car remaining)
                   for element in (cdr remaining)
                   do (setf value (funcall function value element))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=nil key=identity-initial|
    (function list start initial)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) initial)
          (t (loop with value = initial
                   for element in remaining
                   do (setf value (funcall function value element))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=nil key=other-no-initial|
    (function list start key)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) (funcall function))
          ((null (cdr remaining)) (car remaining))
          (t (loop with value = (funcall key (car remaining))
                   for element in (cdr remaining)
                   do (setf value (funcall function
                                           value
                                           (funcall key element)))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=nil key=other-initial|
    (function list start key initial)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) initial)
          (t (loop with value = initial
                   for element in remaining
                   do (setf value (funcall function
                                           value
                                           (funcall key element)))
                   finally (return value))))))


(defun |reduce seq-type=list from-end=false end=other key=identity-no-initial|
    (function list start end)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) (funcall function))
          ((null (cdr remaining)) (car remaining))
          (t (loop with value = (car remaining)
                   for element in (cdr remaining)
                   repeat (- end start 1)
                   do (setf value (funcall function value element))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=other key=identity-initial|
    (function list start end initial)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) initial)
          (t (loop with value = initial
                   for element in remaining
                   repeat (- end start)
                   do (setf value (funcall function value element))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=other key=other-no-initial|
    (function list start end key)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) (funcall function))
          ((null (cdr remaining)) (car remaining))
          (t (loop with value = (funcall key (car remaining))
                   for element in (cdr remaining)
                   repeat (- end start 1)
                   do (setf value (funcall function
                                           value
                                           (funcall key element)))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=false end=other key=other-initial|
    (function list start end key initial)
  (let ((remaining (nthcdr start list)))
    (cond ((null remaining) initial)
          (t (loop with value = initial
                   for element in remaining
                   repeat (- end start)
                   do (setf value (funcall function
                                           value
                                           (funcall key element)))
                   finally (return value))))))

(defun |reduce seq-type=list from-end=true end=nil key=identity-no-initial|
    (function list start)
  (|reduce seq-type=list from-end=false end=nil key=identity-no-initial|
   function (reverse (nthcdr start list)) 0))

(defun |reduce seq-type=list from-end=true end=nil key=identity-initial|
    (function list start initial)
  (|reduce seq-type=list from-end=false end=nil key=identity-initial|
   function (reverse (nthcdr start list)) 0 initial))

(defun |reduce seq-type=list from-end=true end=nil key=other-no-initial|
    (function list start key)
  (|reduce seq-type=list from-end=false end=nil key=other-no-initial|
   function (reverse (nthcdr start list)) 0 key))

(defun |reduce seq-type=list from-end=true end=nil key=other-initial|
    (function list start key initial)
  (|reduce seq-type=list from-end=false end=nil key=other-initial|
   function (reverse (nthcdr start list)) 0 key initial))

(defun |reduce seq-type=list from-end=true end=other key=identity-no-initial|
    (function list start end)
  (|reduce seq-type=list from-end=false end=nil key=identity-no-initial|
   function (nreverse (subseq list start end)) 0))

(defun |reduce seq-type=list from-end=true end=other key=identity-initial|
    (function list start end initial)
  (|reduce seq-type=list from-end=false end=nil key=identity-initial|
   function (nreverse (subseq list start end)) 0 initial))

(defun |reduce seq-type=list from-end=true end=other key=other-no-initial|
    (function list start end key)
  (|reduce seq-type=list from-end=false end=nil key=other-no-initial|
   function (nreverse (subseq list start end)) 0 key))

(defun |reduce seq-type=list from-end=true end=other key=other-initial|
    (function list start end key initial)
  (|reduce seq-type=list from-end=false end=nil key=other-initial|
   function (nreverse (subseq list start end)) 0 key initial))

(defun |reduce seq-type=vector from-end=false key=identity-no-initial|
    (function vector start end)
  (cond ((<= end start) (funcall function))
        ((= 1 (- end start)) (aref vector start))
        (t (loop with value = (aref vector start)
                 for index from (1+ start) below end
                 do (setf value (funcall function
                                         value
                                         (aref vector index)))
                 finally (return value)))))

(defun |reduce seq-type=vector from-end=false key=identity-initial|
    (function vector start end initial)
  (cond ((<= end start) initial)
        (t (loop with value = initial
                 for index from start below end
                 do (setf value (funcall function
                                         value
                                         (aref vector index)))
                 finally (return value)))))

(defun |reduce seq-type=vector from-end=false key=other-no-initial|
    (function vector start end key)
  (cond ((<= end start) (funcall function))
        ((= 1 (- end start)) (aref vector start))
        (t (loop with value = (funcall key (aref vector start))
                 for index from (1+ start) below end
                 do (setf value (funcall function
                                         value
                                         (funcall key (aref vector index))))
                 finally (return value)))))


(defun |reduce seq-type=vector from-end=false key=other-initial|
    (function vector start end key initial)
  (cond ((<= end start) initial)
        (t (loop with value = initial
                 for index from start below end
                 do (setf value (funcall function
                                         value
                                         (funcall key (aref vector index))))
                 finally (return value)))))

(defun |reduce seq-type=vector from-end=true key=identity-no-initial|
    (function vector start end)
  (cond ((<= end start) (funcall function))
        ((= 1 (- end start)) (aref vector start))
        (t (loop with value = (aref vector (1- start))
                 for index downfrom (- end 2) to start
                 do (setf value (funcall function
                                         value
                                         (aref vector index)))
                 finally (return value)))))

(defun |reduce seq-type=vector from-end=true key=identity-initial|
    (function vector start end initial)
  (cond ((<= end start) initial)
        (t (loop with value = initial
                 for index downfrom (1- end) to start
                 do (setf value (funcall function
                                         value
                                         (aref vector index)))
                 finally (return value)))))

(defun |reduce seq-type=vector from-end=true key=other-no-initial|
    (function vector start end key)
  (cond ((<= end start) (funcall function))
        ((= 1 (- end start)) (aref vector start))
        (t (loop with value = (funcall key (aref vector (1- end)))
                 for index downfrom (- end 2) to start
                 do (setf value (funcall function
                                         value
                                         (funcall key (aref vector index))))
                 finally (return value)))))


(defun |reduce seq-type=vector from-end=true key=other-initial|
    (function vector start end key initial)
  (cond ((<= end start) initial)
        (t (loop with value = initial
                 for index downfrom (1- end) to start
                 do (setf value (funcall function
                                         value
                                         (funcall key (aref vector index))))
                 finally (return value)))))

(defun |reduce from-end=false end=nil key=identity-no-initial|
    (function sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=false key=identity-no-initial|
        function sequence start (length sequence)))
    (list 
       (|reduce seq-type=list from-end=false end=nil key=identity-no-initial|
        function sequence start))))
       
(defun |reduce from-end=false end=nil key=identity-initial|
    (function sequence start initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=false key=identity-initial|
        function sequence start (length sequence) initial))
    (list 
       (|reduce seq-type=list from-end=false end=nil key=identity-initial|
        function sequence start initial))))

(defun |reduce from-end=false end=nil key=other-no-initial|
    (function sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=false key=other-no-initial|
        function sequence start (length sequence) key))
    (list 
       (|reduce seq-type=list from-end=false end=nil key=other-no-initial|
        function sequence start key))))
       
(defun |reduce from-end=false end=nil key=other-initial|
    (function sequence start key initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=false key=other-initial|
        function sequence start (length sequence) key initial))
    (list 
       (|reduce seq-type=list from-end=false end=nil key=other-initial|
        function sequence start key initial))))

(defun |reduce from-end=false end=other key=identity-no-initial|
    (function sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=false key=identity-no-initial|
        function sequence start end))
    (list 
       (|reduce seq-type=list from-end=false end=other key=identity-no-initial|
        function sequence start end))))
       
(defun |reduce from-end=false end=other key=identity-initial|
    (function sequence start end initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=false key=identity-initial|
        function sequence start end initial))
    (list 
       (|reduce seq-type=list from-end=false end=other key=identity-initial|
        function sequence start end initial))))

(defun |reduce from-end=false end=other key=other-no-initial|
    (function sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=false key=other-no-initial|
        function sequence start end key))
    (list 
       (|reduce seq-type=list from-end=false end=other key=other-no-initial|
        function sequence start end key))))
       
(defun |reduce from-end=false end=other key=other-initial|
    (function sequence start end key initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=false key=other-initial|
        function sequence start end key initial))
    (list 
       (|reduce seq-type=list from-end=false end=other key=other-initial|
        function sequence start end key initial))))

(defun |reduce from-end=true end=nil key=identity-no-initial|
    (function sequence start)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=true key=identity-no-initial|
        function sequence start (length sequence)))
    (list 
       (|reduce seq-type=list from-end=true end=nil key=identity-no-initial|
        function sequence start))))
       
(defun |reduce from-end=true end=nil key=identity-initial|
    (function sequence start initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=true key=identity-initial|
        function sequence start (length sequence) initial))
    (list 
       (|reduce seq-type=list from-end=true end=nil key=identity-initial|
        function sequence start initial))))

(defun |reduce from-end=true end=nil key=other-no-initial|
    (function sequence start key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=true key=other-no-initial|
        function sequence start (length sequence) key))
    (list 
       (|reduce seq-type=list from-end=true end=nil key=other-no-initial|
        function sequence start key))))
       
(defun |reduce from-end=true end=nil key=other-initial|
    (function sequence start key initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start (length sequence))
       (|reduce seq-type=vector from-end=true key=other-initial|
        function sequence start (length sequence) key initial))
    (list 
       (|reduce seq-type=list from-end=true end=nil key=other-initial|
        function sequence start key initial))))

(defun |reduce from-end=true end=other key=identity-no-initial|
    (function sequence start end)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=true key=identity-no-initial|
        function sequence start end))
    (list 
       (|reduce seq-type=list from-end=true end=other key=identity-no-initial|
        function sequence start end))))
       
(defun |reduce from-end=true end=other key=identity-initial|
    (function sequence start end initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=true key=identity-initial|
        function sequence start end initial))
    (list 
       (|reduce seq-type=list from-end=true end=other key=identity-initial|
        function sequence start end initial))))

(defun |reduce from-end=true end=other key=other-no-initial|
    (function sequence start end key)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=true key=other-no-initial|
        function sequence start end key))
    (list 
       (|reduce seq-type=list from-end=true end=other key=other-no-initial|
        function sequence start end key))))
       
(defun |reduce from-end=true end=other key=other-initial|
    (function sequence start end key initial)
  (etypecase sequence
    (vector
       (verify-bounding-indexes 'reduce sequence start end)
       (|reduce seq-type=vector from-end=true key=other-initial|
        function sequence start end key initial))
    (list 
       (|reduce seq-type=list from-end=true end=other key=other-initial|
        function sequence start end key initial))))

(defun reduce (function sequence
               &key
               key
               from-end
               (start 0)
               end
               (initial-value nil initial-value-p))
    (if from-end
        (if key
          (if end
              (if initial-value-p
                  (|reduce from-end=true end=other key=other-initial|
                   function sequence start end key initial-value)
                  (|reduce from-end=true end=other key=other-no-initial|
                   function sequence start end key))
              (if initial-value-p
                  (|reduce from-end=true end=nil key=other-initial|
                   function sequence start key initial-value)
                  (|reduce from-end=true end=nil key=other-no-initial|
                   function sequence start key)))
          (if end
              (if initial-value-p
                  (|reduce from-end=true end=other key=identity-initial|
                   function sequence start end initial-value)
                  (|reduce from-end=true end=other key=identity-no-initial|
                   function sequence start end))
              (if initial-value-p
                  (|reduce from-end=true end=nil key=identity-initial|
                   function sequence start initial-value)
                  (|reduce from-end=true end=nil key=identity-no-initial|
                   function sequence start))))
        (if key
          (if end
              (if initial-value-p
                  (|reduce from-end=false end=other key=other-initial|
                   function sequence start end key initial-value)
                  (|reduce from-end=false end=other key=other-no-initial|
                   function sequence start end key))
              (if initial-value-p
                  (|reduce from-end=false end=nil key=other-initial|
                   function sequence start key initial-value)
                  (|reduce from-end=false end=nil key=other-no-initial|
                   function sequence start key)))
          (if end
              (if initial-value-p
                  (|reduce from-end=false end=other key=identity-initial|
                   function sequence start end initial-value)
                  (|reduce from-end=false end=other key=identity-no-initial|
                   function sequence start end))
              (if initial-value-p
                  (|reduce from-end=false end=nil key=identity-initial|
                   function sequence start initial-value)
                  (|reduce from-end=false end=nil key=identity-no-initial|
                   function sequence start))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function fill

(defun |fill seq-type=list end=nil|
    (list item start)
  (loop for sublist on (nthcdr start list)
        do (setf (car sublist) item))
  list)

(defun |fill seq-type=list end=other|
    (list item start end)
  (loop for sublist on (nthcdr start list)
        repeat (- end start)
        do (setf (car sublist) item))
  list)

(defun |fill-vector|
    (vector item start end)
  (loop for index from start below end
        do (setf (aref vector index) item))
  vector)

(defun fill (sequence item
             &key
             (start 0)
             end)
  (etypecase sequence
    (vector
       (if end
           (|fill-vector| sequence item start end)
           (|fill-vector| sequence item start (length sequence))))
    (list
       (if end
           (|fill seq-type=list end=other| sequence item start end)
           (|fill seq-type=list end=nil| sequence item start)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function remove

;;; It is not worth the effort to specialize for a start value of 0
;;; because that only implies a single test at the beginning of the
;;; function, but it is worth specializing for an end value of nil
;;; when the sequence is a list.

;;; For lists, the technique is to allocate a single sentinel cons
;;; cell that acts as a queue.  Then we fill up the end of the queue
;;; with elements of the list that should be kept.  Finally we return
;;; the cdr of the initial cons cell.  This technique avoids some
;;; special cases at the cost of allocating another cons cell. 

(defun |remove seq-type=list end=nil test=eql count=nil key=identity|
    (item list start)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (eql item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=nil test=eq count=nil key=identity|
    (item list start)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (eq item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=nil test=eql count=nil key=other|
    (item list start key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (eql item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=nil test=eq count=nil key=other|
    (item list start key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (eq item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=eql count=nil key=identity|
    (item list start end)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (eql item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=eq count=nil key=identity|
    (item list start end)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (eq item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=eql count=nil key=other|
    (item list start end key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (eql item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=eq count=nil key=other|
    (item list start end key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (eq item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list end=nil test=other count=nil key=identity|
    (item list start test)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (funcall test item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=nil test=other count=nil key=other|
    (item list start test key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (funcall test item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=other count=nil key=identity|
    (item list start end test)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (funcall test item  element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list end=other test=other count=nil key=other|
    (item list start end test key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (funcall test item  (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list test-not=other end=nil count=nil key=identity|
    (item list start test-not)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  when (funcall test-not item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list test-not=other end=nil count=nil key=other|
    (item list start test-not key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  when (funcall test-not item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove seq-type=list test-not=other end=other count=nil key=identity|
    (item list start end test-not)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  when (funcall test-not item  element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list test-not=other end=other count=nil key=other|
    (item list start end test-not key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  when (funcall test-not item  (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=eql count=other key=identity|
    (item list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (eql item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=eq count=other key=identity|
    (item list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (eq item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=eql count=other key=other|
    (item list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (eql item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=eq count=other key=other|
    (item list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (eq item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=eql count=other key=identity|
    (item list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (eql item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=eq count=other key=identity|
    (item list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (eq item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=eql count=other key=other|
    (item list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (eql item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=eq count=other key=other|
    (item list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (eq item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=other count=other key=identity|
    (item list start test count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (funcall test item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=nil test=other count=other key=other|
    (item list start test count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (funcall test item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=other count=other key=identity|
    (item list start end test count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (funcall test item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false end=other test=other count=other key=other|
    (item list start end test count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (funcall test item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false test-not=other end=nil count=other key=identity|
    (item list start test-not count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  when (funcall test-not item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false test-not=other end=nil count=other key=other|
    (item list start test-not count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  when (funcall test-not item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false test-not=other end=other count=other key=identity|
    (item list start end test-not count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  when (funcall test-not item element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=false test-not=other end=other count=other key=other|
    (item list start end test-not count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  when (funcall test-not item (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=eql count=other key=identity|
    (item list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eql item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=eq count=other key=identity|
    (item list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eq item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=eql count=other key=other|
    (item list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eql item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=eq count=other key=other|
    (item list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eq item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=eql count=other key=identity|
    (item list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eql item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=eq count=other key=identity|
    (item list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eq item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=eql count=other key=other|
    (item list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eql item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=eq count=other key=other|
    (item list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (eq item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=other count=other key=identity|
    (item list start test count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall test item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=nil test=other count=other key=other|
    (item list start test count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall test item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=other count=other key=identity|
    (item list start end test count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall test item element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true end=other test=other count=other key=other|
    (item list start end test count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall test item (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true test-not=other end=nil count=other key=identity|
    (item list start test-not count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall test-not item element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true test-not=other end=nil count=other key=other|
    (item list start test-not count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall test-not item (funcall key element)))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true test-not=other end=other count=other key=identity|
    (item list start end test-not count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall test-not item element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove seq-type=list from-end=true test-not=other end=other count=other key=other|
    (item list start end test-not count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall test-not item (funcall key element)))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

;;; Helper function. 
;;; FIXME: try to explain what it does!
(defun copy-result-general (original-vector start end bit-vector delete-count)
  (declare (type simple-bit-vector bit-vector)
	   (type fixnum start end delete-count))
  (if (zerop delete-count)
      original-vector
      (let* ((length (length original-vector))
	     (result (make-array (- length delete-count)
				 :element-type (array-element-type original-vector))))
	;; Copy the prefix
	(loop for i from 0 below start
	      do (setf (svref result i) (aref original-vector i)))
	;; Copy elements marked by the bitmap
	(loop with result-index = start
	      for source-index from start below end
	      when (= 1 (bit bit-vector (- source-index start)))
		do (setf (svref result result-index)
			 (aref original-vector source-index))
		   (incf result-index))
	;; Copy the suffix
	(loop for source-index from end below length
	      for result-index from (- end delete-count)
	      do (setf (svref result result-index)
		       (aref original-vector source-index)))
	result)))

(defun |remove seq-type=general-vector test=eql count=nil key=identity|
    (item vector start end)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test=eq count=nil key=identity|
    (item vector start end)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test=eql count=nil key=other|
    (item vector start end key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test=eq count=nil key=other|
    (item vector start end key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test=other count=nil key=identity|
    (item vector start end test)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test=other count=nil key=other|
    (item vector start end test key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test-not=other count=nil key=identity|
    (item vector start end test-not)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  unless (funcall test-not item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector test-not=other count=nil key=other|
    (item vector start end test-not key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test-not item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=eql count=other key=identity|
    (item vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=eq count=other key=identity|
    (item vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=eql count=other key=other|
    (item vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=eq count=other key=other|
    (item vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=other count=other key=identity|
    (item vector start end test count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test=other count=other key=other|
    (item vector start end test count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test-not=other count=other key=identity|
    (item vector start end test-not count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=false test-not=other count=other key=other|
    (item vector start end test-not count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=eql count=other key=identity|
    (item vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=eq count=other key=identity|
    (item vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=eql count=other key=other|
    (item vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=eq count=other key=other|
    (item vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=other count=other key=identity|
    (item vector start end test count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test=other count=other key=other|
    (item vector start end test count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test-not=other count=other key=identity|
    (item vector start end test-not count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove seq-type=general-vector from-end=true test-not=other count=other key=other|
    (item vector start end test-not count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	  else
	    do (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

;;; For vectors, the technique used is to allocate a bitvector that
;;; has the length of the interval in which elements should be
;;; removed, i.e. end - start.  Elements to keep are then marked with
;;; a 1 in that bitvector, and at the same time, we count the number
;;; of 1s.  Finally, we allocate a vector of the correct size, copy
;;; the prefix of the original vector (before start), the elements of
;;; the original vector marked by a 1 in the bitvector in the interval
;;; between start and end, and the suffix of the original vector
;;; (after end).  This technique has the disadvantage that elements of
;;; the original vector in the interval between start and end have to
;;; be accessed twice; once in order to apply the test to see whether
;;; to mark them in the bitvector, and once more to move them from the
;;; original vector to the result vector.  And of course, the
;;; bitvector has to be manipulated as well.  For very quick
;;; combinations of tests and keys, for instance eq and identity, it
;;; may be faster to apply the test twice; once by going through the
;;; original vector and just counting the number of elements to keep,
;;; and then once more in order to move from the original to the
;;; resulting vector.  That method would save the bitvector
;;; manipulation, but it would access *all* of the elements in the the
;;; interval between start and end twice, not only those that are to
;;; be kept.

;;; Helper function. 
;;; FIXME: try to explain what it does!
(defun copy-result-simple (original-vector start end bit-vector delete-count)
  (declare (type simple-vector original-vector)
	   (type simple-bit-vector bit-vector)
	   (type fixnum start end delete-count))
  (if (zerop delete-count)
      original-vector
      (let* ((length (length original-vector))
	     (result (make-array (- length delete-count)
				 :element-type (array-element-type original-vector))))
	;; Copy the prefix
	(loop for i from 0 below start
	      do (setf (svref result i) (svref original-vector i)))
	;; Copy elements marked by the bitmap
	(loop with result-index = start
	      for source-index from start below end
	      when (= 1 (bit bit-vector (- source-index start)))
		do (setf (svref result result-index)
			 (svref original-vector source-index))
		   (incf result-index))
	;; Copy the suffix
	(loop for source-index from end below length
	      for result-index from (- end delete-count)
	      do (setf (svref result result-index)
		       (svref original-vector source-index)))
	result)))

(defun |remove seq-type=simple-vector test=eql count=nil key=identity|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test=eq count=nil key=identity|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test=eql count=nil key=other|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test=eq count=nil key=other|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test=other count=nil key=identity|
    (item vector start end test)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test=other count=nil key=other|
    (item vector start end test key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test-not=other count=nil key=identity|
    (item vector start end test-not)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  unless (funcall test-not item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector test-not=other count=nil key=other|
    (item vector start end test-not key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  unless (funcall test-not item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
    (item vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=eq count=other key=identity|
    (item vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=eql count=other key=other|
    (item vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=eq count=other key=other|
    (item vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=other count=other key=identity|
    (item vector start end test count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test=other count=other key=other|
    (item vector start end test count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test-not=other count=other key=identity|
    (item vector start end test-not count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=false test-not=other count=other key=other|
    (item vector start end test-not count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
    (item vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=eq count=other key=identity|
    (item vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=eql count=other key=other|
    (item vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=eq count=other key=other|
    (item vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=other count=other key=identity|
    (item vector start end test count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test=other count=other key=other|
    (item vector start end test count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test-not=other count=other key=identity|
    (item vector start end test-not count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-vector from-end=true test-not=other count=other key=other|
    (item vector start end test-not count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

;;; Helper function. 
;;; FIXME: try to explain what it does!
(defun copy-result-simple-string (original-vector start end bit-vector delete-count)
  (declare (type simple-string original-vector)
	   (type simple-bit-vector bit-vector)
	   (type fixnum start end delete-count))
  (if (zerop delete-count)
      original-vector
      (let* ((length (length original-vector))
	     (result (make-array (- length delete-count)
				 :element-type (array-element-type original-vector))))
	;; Copy the prefix
	(loop for i from 0 below start
	      do (setf (svref result i) (schar original-vector i)))
	;; Copy elements marked by the bitmap
	(loop with result-index = start
	      for source-index from start below end
	      when (= 1 (bit bit-vector (- source-index start)))
		do (setf (svref result result-index)
			 (schar original-vector source-index))
		   (incf result-index))
	;; Copy the suffix
	(loop for source-index from end below length
	      for result-index from (- end delete-count)
	      do (setf (svref result result-index)
		       (schar original-vector source-index)))
	result)))

(defun |remove seq-type=simple-string test=eql count=nil key=identity|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test=eq count=nil key=identity|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test=eql count=nil key=other|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eql item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test=eq count=nil key=other|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (eq item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test=other count=nil key=identity|
    (item vector start end test)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test=other count=nil key=other|
    (item vector start end test key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall test item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test-not=other count=nil key=identity|
    (item vector start end test-not)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  unless (funcall test-not item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string test-not=other count=nil key=other|
    (item vector start end test-not key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  unless (funcall test-not item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=eql count=other key=identity|
    (item vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=eq count=other key=identity|
    (item vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=eql count=other key=other|
    (item vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eql item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=eq count=other key=other|
    (item vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (eq item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=other count=other key=identity|
    (item vector start end test count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test=other count=other key=other|
    (item vector start end test count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall test item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test-not=other count=other key=identity|
    (item vector start end test-not count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=false test-not=other count=other key=other|
    (item vector start end test-not count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  unless (funcall test-not item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=eql count=other key=identity|
    (item vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=eq count=other key=identity|
    (item vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=eql count=other key=other|
    (item vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eql item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=eq count=other key=other|
    (item vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (eq item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=other count=other key=identity|
    (item vector start end test count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test=other count=other key=other|
    (item vector start end test count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall test item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test-not=other count=other key=identity|
    (item vector start end test-not count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove seq-type=simple-string from-end=true test-not=other count=other key=other|
    (item vector start end test-not count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  unless (funcall test-not item (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove end=nil test=eql count=nil key=identity|
    (item sequence start)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=eql count=nil key=identity|
	  item sequence start))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eql count=nil key=identity|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eql count=nil key=identity|
	  item sequence start (length sequence)))
	(t
	 (|remove seq-type=general-vector test=eql count=nil key=identity|
	  item sequence start (length sequence)))))

(defun |remove end=nil test=eq count=nil key=identity|
    (item sequence start)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=eq count=nil key=identity|
	  item sequence start))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eq count=nil key=identity|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eq count=nil key=identity|
	  item sequence start (length sequence)))
	(t
	 (|remove seq-type=general-vector test=eq count=nil key=identity|
	  item sequence start (length sequence)))))

(defun |remove end=nil test=other count=nil key=identity|
    (item sequence start test)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=other count=nil key=identity|
	  item sequence start test))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=other count=nil key=identity|
	  item sequence start (length sequence) test))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=other count=nil key=identity|
	  item sequence start (length sequence) test))
	(t
	 (|remove seq-type=general-vector test=other count=nil key=identity|
	  item sequence start (length sequence) test))))

(defun |remove end=nil test=eql count=nil key=other|
    (item sequence start key)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=eql count=nil key=other|
	  item sequence start key))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eql count=nil key=other|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eql count=nil key=other|
	  item sequence start (length sequence) key))
	(t
	 (|remove seq-type=general-vector test=eql count=nil key=other|
	  item sequence start (length sequence) key))))

(defun |remove end=nil test=eq count=nil key=other|
    (item sequence start key)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=eq count=nil key=other|
	  item sequence start key))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eq count=nil key=other|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eq count=nil key=other|
	  item sequence start (length sequence) key))
	(t
	 (|remove seq-type=general-vector test=eq count=nil key=other|
	  item sequence start (length sequence) key))))

(defun |remove end=nil test=other count=nil key=other|
    (item sequence start test key)
  (cond ((listp sequence)
	 (|remove seq-type=list end=nil test=other count=nil key=other|
	  item sequence start test key))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=other count=nil key=other|
	  item sequence start (length sequence) test key))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=other count=nil key=other|
	  item sequence start (length sequence) test key))
	(t
	 (|remove seq-type=general-vector test=other count=nil key=other|
	  item sequence start (length sequence) test key))))

(defun |remove end=other test=eql count=nil key=identity|
    (item sequence start end)
  (cond ((listp sequence)
	 (|remove seq-type=list end=other test=eql count=nil key=identity|
	  item sequence start end))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eql count=nil key=identity|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eql count=nil key=identity|
	  item sequence start end))
	(t
	 (|remove seq-type=general-vector test=eql count=nil key=identity|
	  item sequence start end))))

(defun |remove end=other test=eq count=nil key=identity|
    (item sequence start end)
  (cond ((listp sequence)
	 (|remove seq-type=list end=other test=eq count=nil key=identity|
	  item sequence start end))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eq count=nil key=identity|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eq count=nil key=identity|
	  item sequence start end))
	(t
	 (|remove seq-type=general-vector test=eq count=nil key=identity|
	  item sequence start end))))

(defun |remove end=other test=eql count=nil key=other|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|remove seq-type=list end=other test=eql count=nil key=other|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eql count=nil key=other|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eql count=nil key=other|
	  item sequence start end key))
	(t
	 (|remove seq-type=general-vector test=eql count=nil key=other|
	  item sequence start end key))))

(defun |remove end=other test=eq count=nil key=other|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|remove seq-type=list end=other test=eq count=nil key=other|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|remove seq-type=simple-string test=eq count=nil key=other|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|remove seq-type=simple-vector test=eq count=nil key=other|
	  item sequence start end key))
	(t
	 (|remove seq-type=general-vector test=eq count=nil key=other|
	  item sequence start end key))))

(defun remove (item sequence
	       &key
	       from-end
	       (test nil test-p)
	       (test-not nil test-not-p)
	       (start 0)
	       end
	       count
	       key)
  (when (and test-p test-not-p)
    (error 'both-test-and-test-not-given
	   :name 'remove))
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true end=other test=eq count=other key=other|
			       item sequence start end count key)
			      (|remove seq-type=list from-end=true end=other test=eq count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|remove seq-type=list end=other test=eq count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=list end=other test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true end=nil test=eq count=other key=other|
			       item sequence start count key)
			      (|remove seq-type=list from-end=true end=nil test=eq count=other key=identity|
			       item sequence start count))
			  (if key
			      (|remove seq-type=list end=nil test=eq count=nil key=other|
			       item sequence start key)
			      (|remove seq-type=list end=nil test=eq count=nil key=identity|
			       item sequence start))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if key
				  (|remove seq-type=list from-end=true end=other test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=list from-end=true end=other test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=list end=other test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=list end=other test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if key
				  (|remove seq-type=list from-end=true end=nil test=eql count=other key=other|
				   item sequence start count key)
				  (|remove seq-type=list from-end=true end=nil test=eql count=other key=identity|
				   item sequence start count))
			      (if key
				  (|remove seq-type=list end=nil test=eql count=nil key=other|
				   item sequence start key)
				  (|remove seq-type=list end=nil test=eql count=nil key=identity|
				   item sequence start))))
		      (if end
			  (if count
			      (if key
				  (|remove seq-type=list from-end=true end=other test=other count=other key=other|
				   item sequence start end test count key)
				  (|remove seq-type=list from-end=true end=other test=other count=other key=identity|
				   item sequence start end test count))
			      (if key
				  (|remove seq-type=list end=other test=other count=nil key=other|
				   item sequence start end test key)
				  (|remove seq-type=list end=other test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if key
				  (|remove seq-type=list from-end=true end=nil test=other count=other key=other|
				   item sequence start test count key)
				  (|remove seq-type=list from-end=true end=nil test=other count=other key=identity|
				   item sequence start test count))
			      (if key
				  (|remove seq-type=list end=nil test=other count=nil key=other|
				   item sequence start test key)
				  (|remove seq-type=list end=nil test=other count=nil key=identity|
				   item sequence start test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true test-not=other end=other count=other key=other|
			       item sequence start end test-not count key)
			      (|remove seq-type=list from-end=true test-not=other end=other count=other key=identity|
			       item sequence start end test-not count))
			  (if key
			      (|remove seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|remove seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true test-not=other end=nil count=other key=other|
			       item sequence start test-not count key)
			      (|remove seq-type=list from-end=true test-not=other end=nil count=other key=identity|
			       item sequence start test-not count))
			  (if key
			      (|remove seq-type=list test-not=other end=nil count=nil key=other|
			       item sequence start test-not key)
			      (|remove seq-type=list test-not=other end=nil count=nil key=identity|
			       item sequence start test-not))))
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true end=other test=eql count=other key=other|
			       item sequence start end count key)
			      (|remove seq-type=list from-end=true end=other test=eql count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|remove seq-type=list end=other test=eql count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=list end=other test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=true end=nil test=eql count=other key=other|
			       item sequence start count key)
			      (|remove seq-type=list from-end=true end=nil test=eql count=other key=identity|
			       item sequence start count))
			  (if key
			      (|remove seq-type=list end=nil test=eql count=nil key=other|
			       item sequence start key)
			      (|remove seq-type=list end=nil test=eql count=nil key=identity|
			       item sequence start))))))
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false end=other test=eq count=other key=other|
			       item sequence start end count key)
			      (|remove seq-type=list from-end=false end=other test=eq count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|remove seq-type=list end=other test=eq count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=list end=other test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false end=nil test=eq count=other key=other|
			       item sequence start count key)
			      (|remove seq-type=list from-end=false end=nil test=eq count=other key=identity|
			       item sequence start count))
			  (if key
			      (|remove seq-type=list end=nil test=eq count=nil key=other|
			       item sequence start key)
			      (|remove seq-type=list end=nil test=eq count=nil key=identity|
			       item sequence start))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if key
				  (|remove seq-type=list from-end=false end=other test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=list from-end=false end=other test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=list end=other test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=list end=other test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if key
				  (|remove seq-type=list from-end=false end=nil test=eql count=other key=other|
				   item sequence start count key)
				  (|remove seq-type=list from-end=false end=nil test=eql count=other key=identity|
				   item sequence start count))
			      (if key
				  (|remove seq-type=list end=nil test=eql count=nil key=other|
				   item sequence start key)
				  (|remove seq-type=list end=nil test=eql count=nil key=identity|
				   item sequence start))))
		      (if end
			  (if count
			      (if key
				  (|remove seq-type=list from-end=false end=other test=other count=other key=other|
				   item sequence start end test count key)
				  (|remove seq-type=list from-end=false end=other test=other count=other key=identity|
				   item sequence start end test count))
			      (if key
				  (|remove seq-type=list end=other test=other count=nil key=other|
				   item sequence start end test key)
				  (|remove seq-type=list end=other test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if key
				  (|remove seq-type=list from-end=false end=nil test=other count=other key=other|
				   item sequence start test count key)
				  (|remove seq-type=list from-end=false end=nil test=other count=other key=identity|
				   item sequence start test count))
			      (if key
				  (|remove seq-type=list end=nil test=other count=nil key=other|
				   item sequence start test key)
				  (|remove seq-type=list end=nil test=other count=nil key=identity|
				   item sequence start test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false test-not=other end=other count=other key=other|
			       item sequence start end test-not count key)
			      (|remove seq-type=list from-end=false test-not=other end=other count=other key=identity|
			       item sequence start end test-not count))
			  (if key
			      (|remove seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|remove seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false test-not=other end=nil count=other key=other|
			       item sequence start test-not count key)
			      (|remove seq-type=list from-end=false test-not=other end=nil count=other key=identity|
			       item sequence start test-not count))
			  (if key
			      (|remove seq-type=list test-not=other end=nil count=nil key=other|
			       item sequence start test-not key)
			      (|remove seq-type=list test-not=other end=nil count=nil key=identity|
			       item sequence start test-not))))
		  (if end
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false end=other test=eql count=other key=other|
			       item sequence start end count key)
			      (|remove seq-type=list from-end=false end=other test=eql count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|remove seq-type=list end=other test=eql count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=list end=other test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|remove seq-type=list from-end=false end=nil test=eql count=other key=other|
			       item sequence start count key)
			      (|remove seq-type=list from-end=false end=nil test=eql count=other key=identity|
			       item sequence start count))
			  (if key
			      (|remove seq-type=list end=nil test=eql count=nil key=other|
			       item sequence start key)
			      (|remove seq-type=list end=nil test=eql count=nil key=identity|
			       item sequence start)))))))
      (if (simple-string-p sequence)
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=identity|
				   item sequence start end count)))
			  (if key
			      (|remove seq-type=simple-string test=eq count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=simple-string test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=identity|
				   item sequence start (length sequence) count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=identity|
				   item sequence start (length sequence) count)))
			  (if key
			      (|remove seq-type=simple-string test=eq count=nil key=other|
			       item sequence start (length sequence) key)
			      (|remove seq-type=simple-string test=eq count=nil key=identity|
			       item sequence start (length sequence)))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-string test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-string test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-string test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-string test=eql count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=other count=other key=other|
				       item sequence start end test count key)
				      (|remove seq-type=simple-string from-end=true test=other count=other key=identity|
				       item sequence start end test count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=other count=other key=other|
				       item sequence start end test count key)
				      (|remove seq-type=simple-string from-end=false test=other count=other key=identity|
				       item sequence start end test count)))
			      (if key
				  (|remove seq-type=simple-string test=other count=nil key=other|
				   item sequence start end test key)
				  (|remove seq-type=simple-string test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=other count=other key=other|
				       item sequence start (length sequence) test count key)
				      (|remove seq-type=simple-string from-end=true test=other count=other key=identity|
				       item sequence start (length sequence) test count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=other count=other key=other|
				       item sequence start (length sequence) test count key)
				      (|remove seq-type=simple-string from-end=false test=other count=other key=identity|
				       item sequence start (length sequence) test count)))
			      (if key
				  (|remove seq-type=simple-string test=other count=nil key=other|
				   item sequence start (length sequence) test key)
				  (|remove seq-type=simple-string test=other count=nil key=identity|
				   item sequence start (length sequence) test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=other|
				   item sequence start end test-not count key)
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=identity|
				   item sequence start end test-not count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=other|
				   item sequence start end test-not count key)
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=identity|
				   item sequence start end test-not count)))
			  (if key
			      (|remove seq-type=simple-string test-not=other count=nil key=other|
			       item sequence start end test-not key)
			      (|remove seq-type=simple-string test-not=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=other|
				   item sequence start (length sequence) test-not count key)
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=identity|
				   item sequence start (length sequence) test-not count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=other|
				   item sequence start (length sequence) test-not count key)
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=identity|
				   item sequence start (length sequence) test-not count)))
			  (if key
			      (|remove seq-type=simple-string test-not=other count=nil key=other|
			       item sequence start (length sequence) test-not key)
			      (|remove seq-type=simple-string test-not=other count=nil key=identity|
			       item sequence start (length sequence) test-not))))
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				   item sequence start end count)))
			  (if key
			      (|remove seq-type=simple-string test=eql count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=simple-string test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				   item sequence start (length sequence) count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				   item sequence start (length sequence) count)))
			  (if key
			      (|remove seq-type=simple-string test=eql count=nil key=other|
			       item sequence start (length sequence) key)
			      (|remove seq-type=simple-string test=eql count=nil key=identity|
			       item sequence start (length sequence)))))))
	  (if (simple-vector-p sequence)
	      (if test-p
		  (if (or (eq test 'eq) (eq test #'eq))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-vector test=eq count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-vector test=eq count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-vector test=eq count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-vector test=eq count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if (or (eq test 'eql) (eq test #'eql))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
					   item sequence start end count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
					   item sequence start end count)))
				  (if key
				      (|remove seq-type=simple-vector test=eql count=nil key=other|
				       item sequence start end key)
				      (|remove seq-type=simple-vector test=eql count=nil key=identity|
				       item sequence start end)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
					   item sequence start (length sequence) count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
					   item sequence start (length sequence) count)))
				  (if key
				      (|remove seq-type=simple-vector test=eql count=nil key=other|
				       item sequence start (length sequence) key)
				      (|remove seq-type=simple-vector test=eql count=nil key=identity|
				       item sequence start (length sequence)))))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=identity|
					   item sequence start end test count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=identity|
					   item sequence start end test count)))
				  (if key
				      (|remove seq-type=simple-vector test=other count=nil key=other|
				       item sequence start end test key)
				      (|remove seq-type=simple-vector test=other count=nil key=identity|
				       item sequence start end test)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=identity|
					   item sequence start (length sequence) test count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=identity|
					   item sequence start (length sequence) test count)))
				  (if key
				      (|remove seq-type=simple-vector test=other count=nil key=other|
				       item sequence start (length sequence) test key)
				      (|remove seq-type=simple-vector test=other count=nil key=identity|
				       item sequence start (length sequence) test))))))
		  (if test-not-p
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=identity|
				       item sequence start end test-not count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=identity|
				       item sequence start end test-not count)))
			      (if key
				  (|remove seq-type=simple-vector test-not=other count=nil key=other|
				   item sequence start end test-not key)
				  (|remove seq-type=simple-vector test-not=other count=nil key=identity|
				   item sequence start end test-not)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count)))
			      (if key
				  (|remove seq-type=simple-vector test-not=other count=nil key=other|
				   item sequence start (length sequence) test-not key)
				  (|remove seq-type=simple-vector test-not=other count=nil key=identity|
				   item sequence start (length sequence) test-not))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-vector test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-vector test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-vector test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-vector test=eql count=nil key=identity|
				   item sequence start (length sequence)))))))
	      (if test-p
		  (if (or (eq test 'eq) (eq test #'eq))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=general-vector test=eq count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=general-vector test=eq count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=general-vector test=eq count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=general-vector test=eq count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if (or (eq test 'eql) (eq test #'eql))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
					   item sequence start end count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
					   item sequence start end count)))
				  (if key
				      (|remove seq-type=general-vector test=eql count=nil key=other|
				       item sequence start end key)
				      (|remove seq-type=general-vector test=eql count=nil key=identity|
				       item sequence start end)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
					   item sequence start (length sequence) count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
					   item sequence start (length sequence) count)))
				  (if key
				      (|remove seq-type=general-vector test=eql count=nil key=other|
				       item sequence start (length sequence) key)
				      (|remove seq-type=general-vector test=eql count=nil key=identity|
				       item sequence start (length sequence)))))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=general-vector from-end=true test=other count=other key=identity|
					   item sequence start end test count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=general-vector from-end=false test=other count=other key=identity|
					   item sequence start end test count)))
				  (if key
				      (|remove seq-type=general-vector test=other count=nil key=other|
				       item sequence start end test key)
				      (|remove seq-type=general-vector test=other count=nil key=identity|
				       item sequence start end test)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=general-vector from-end=true test=other count=other key=identity|
					   item sequence start (length sequence) test count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=general-vector from-end=false test=other count=other key=identity|
					   item sequence start (length sequence) test count)))
				  (if key
				      (|remove seq-type=general-vector test=other count=nil key=other|
				       item sequence start (length sequence) test key)
				      (|remove seq-type=general-vector test=other count=nil key=identity|
				       item sequence start (length sequence) test))))))
		  (if test-not-p
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=identity|
				       item sequence start end test-not count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=identity|
				       item sequence start end test-not count)))
			      (if key
				  (|remove seq-type=general-vector test-not=other count=nil key=other|
				   item sequence start end test-not key)
				  (|remove seq-type=general-vector test-not=other count=nil key=identity|
				   item sequence start end test-not)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count)))
			      (if key
				  (|remove seq-type=general-vector test-not=other count=nil key=other|
				   item sequence start (length sequence) test-not key)
				  (|remove seq-type=general-vector test-not=other count=nil key=identity|
				   item sequence start (length sequence) test-not))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=general-vector test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=general-vector test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=general-vector test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=general-vector test=eql count=nil key=identity|
				   item sequence start (length sequence)))))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function remove-if

(defun |remove-if seq-type=list end=nil count=nil key=identity|
    (predicate list start)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove-if seq-type=list end=nil count=nil key=other|
    (predicate list start key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  unless (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove-if seq-type=list end=other count=nil key=identity|
    (predicate list start end)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (funcall predicate  element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list end=other count=nil key=other|
    (predicate list start end key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  unless (funcall predicate  (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list from-end=false end=nil count=other key=identity|
    (predicate list count start)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list from-end=false end=nil count=other key=other|
    (predicate list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  unless (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list from-end=false end=other count=other key=identity|
    (predicate list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list from-end=false end=other count=other key=other|
    (predicate list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  unless (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if seq-type=list from-end=true end=nil count=other key=identity|
    (predicate list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall predicate element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if seq-type=list from-end=true end=nil count=other key=other|
    (predicate list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall predicate (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if seq-type=list from-end=true end=other count=other key=identity|
    (predicate list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall predicate element)
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if seq-type=list from-end=true end=other count=other key=other|
    (predicate list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (funcall predicate (funcall key element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if seq-type=general-vector count=nil key=identity|
    (predicate vector start end)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if seq-type=general-vector count=nil key=other|
    (predicate vector start end key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if seq-type=general-vector from-end=false count=other key=identity|
    (predicate vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if seq-type=general-vector from-end=false count=other key=other|
    (predicate vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if seq-type=general-vector from-end=true count=other key=identity|
    (predicate vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if seq-type=general-vector from-end=true count=other key=other|
    (predicate vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

;;; For vectors, the technique used is to allocate a bitvector that
;;; has the length of the interval in which elements should be
;;; removed, i.e. end - start.  Elements to keep are then marked with
;;; a 1 in that bitvector, and at the same time, we count the number
;;; of 1s.  Finally, we allocate a vector of the correct size, copy
;;; the prefix of the original vector (before start), the elements of
;;; the original vector marked by a 1 in the bitvector in the interval
;;; between start and end, and the suffix of the original vector
;;; (after end).  This technique has the disadvantage that elements of
;;; the original vector in the interval between start and end have to
;;; be accessed twice; once in order to apply the test to see whether
;;; to mark them in the bitvector, and once more to move them from the
;;; original vector to the result vector.  And of course, the
;;; bitvector has to be manipulated as well.  For very quick
;;; combinations of tests and keys, for instance eq and identity, it
;;; may be faster to apply the test twice; once by going through the
;;; original vector and just counting the number of elements to keep,
;;; and then once more in order to move from the original to the
;;; resulting vector.  That method would save the bitvector
;;; manipulation, but it would access *all* of the elements in the the
;;; interval between start and end twice, not only those that are to
;;; be kept.

(defun |remove-if seq-type=simple-vector count=nil key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-vector count=nil key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-vector from-end=false count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-vector from-end=false count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-vector from-end=true count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-vector from-end=true count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string count=nil key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string count=nil key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string from-end=false count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string from-end=false count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string from-end=true count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if seq-type=simple-string from-end=true count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun remove-if (predicate sequence &key from-end (start 0) end count key)
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if end
	      (if count
		  (if key
		      (|remove-if seq-type=list from-end=true end=other count=other key=other|
		       predicate sequence start end count key)
		      (|remove-if seq-type=list from-end=true end=other count=other key=identity|
		       predicate sequence start end count))
		  (if key
		      (|remove-if seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if seq-type=list end=other count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if key
		      (|remove-if seq-type=list from-end=true end=nil count=other key=other|
		       predicate sequence start count key)
		      (|remove-if seq-type=list from-end=true end=nil count=other key=identity|
		       predicate sequence start count))
		  (if key
		      (|remove-if seq-type=list end=nil count=nil key=other|
		       predicate sequence start key)
		      (|remove-if seq-type=list end=nil count=nil key=identity|
		       predicate sequence start))))
	  (if end
	      (if count
		  (if key
		      (|remove-if seq-type=list from-end=false end=other count=other key=other|
		       predicate sequence start end count key)
		      (|remove-if seq-type=list from-end=false end=other count=other key=identity|
		       predicate sequence start end count))
		  (if key
		      (|remove-if seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if seq-type=list end=other count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if key
		      (|remove-if seq-type=list from-end=false end=nil count=other key=other|
		       predicate sequence start count key)
		      (|remove-if seq-type=list from-end=false end=nil count=other key=identity|
		       predicate sequence start count))
		  (if key
		      (|remove-if seq-type=list end=nil count=nil key=other|
		       predicate sequence start key)
		      (|remove-if seq-type=list end=nil count=nil key=identity|
		       predicate sequence start)))))
      (if (simple-string-p sequence)
	  (if end
	      (if count
		  (if from-end
		      (if key
			  (|remove-if seq-type=simple-string from-end=true count=other key=other|
			   predicate sequence start end count key)
			  (|remove-if seq-type=simple-string from-end=true count=other key=identity|
			   predicate sequence start end count))
		      (if key
			  (|remove-if seq-type=simple-string from-end=false count=other key=other|
			   predicate sequence start end count key)
			  (|remove-if seq-type=simple-string from-end=false count=other key=identity|
			   predicate sequence start end count)))
		  (if key
		      (|remove-if seq-type=simple-string count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if seq-type=simple-string count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if from-end
		      (if key
			  (|remove-if seq-type=simple-string from-end=true count=other key=other|
			   predicate sequence start (length sequence) count key)
			  (|remove-if seq-type=simple-string from-end=true count=other key=identity|
			   predicate sequence start (length sequence) count))
		      (if key
			  (|remove-if seq-type=simple-string from-end=false count=other key=other|
			   predicate sequence start (length sequence) count key)
			  (|remove-if seq-type=simple-string from-end=false count=other key=identity|
			   predicate sequence start (length sequence) count)))
		  (if key
		      (|remove-if seq-type=simple-string count=nil key=other|
		       predicate sequence start (length sequence) key)
		      (|remove-if seq-type=simple-string count=nil key=identity|
		       predicate sequence start (length sequence)))))
	  (if (simple-vector-p sequence)
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=simple-vector from-end=true count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if seq-type=simple-vector from-end=true count=other key=identity|
			       predicate sequence start end count))
			  (if key
			      (|remove-if seq-type=simple-vector from-end=false count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if seq-type=simple-vector from-end=false count=other key=identity|
			       predicate sequence start end count)))
		      (if key
			  (|remove-if seq-type=simple-vector count=nil key=other|
			   predicate sequence start end key)
			  (|remove-if seq-type=simple-vector count=nil key=identity|
			   predicate sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=simple-vector from-end=true count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if seq-type=simple-vector from-end=true count=other key=identity|
			       predicate sequence start (length sequence) count))
			  (if key
			      (|remove-if seq-type=simple-vector from-end=false count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if seq-type=simple-vector from-end=false count=other key=identity|
			       predicate sequence start (length sequence) count)))
		      (if key
			  (|remove-if seq-type=simple-vector count=nil key=other|
			   predicate sequence start (length sequence) key)
			  (|remove-if seq-type=simple-vector count=nil key=identity|
			   predicate sequence start (length sequence)))))
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=general-vector from-end=true count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if seq-type=general-vector from-end=true count=other key=identity|
			       predicate sequence start end count))
			  (if key
			      (|remove-if seq-type=general-vector from-end=false count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if seq-type=general-vector from-end=false count=other key=identity|
			       predicate sequence start end count)))
		      (if key
			  (|remove-if seq-type=general-vector count=nil key=other|
			   predicate sequence start end key)
			  (|remove-if seq-type=general-vector count=nil key=identity|
			   predicate sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=general-vector from-end=true count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if seq-type=general-vector from-end=true count=other key=identity|
			       predicate sequence start (length sequence) count))
			  (if key
			      (|remove-if seq-type=general-vector from-end=false count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if seq-type=general-vector from-end=false count=other key=identity|
			       predicate sequence start (length sequence) count)))
		      (if key
			  (|remove-if seq-type=general-vector count=nil key=other|
			   predicate sequence start (length sequence) key)
			  (|remove-if seq-type=general-vector count=nil key=identity|
			   predicate sequence start (length sequence)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function remove-if-not

(defun |remove-if-not seq-type=list end=nil count=nil key=identity|
    (predicate list start)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  when (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list end=nil count=nil key=other|
    (predicate list start key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (atom remaining)
	  for element = (car remaining)
	  when (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list 'remove list remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list end=other count=nil key=identity|
    (predicate list start end)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  when (funcall predicate  element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list end=other count=nil key=other|
    (predicate list start end key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end))
	  for element = (car remaining)
	  when (funcall predicate  (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=false end=nil count=other key=identity|
    (predicate list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  when (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=false end=nil count=other key=other|
    (predicate list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (zerop count))
	  for element = (car remaining)
	  when (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list 'remove list remaining)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=false end=other count=other key=identity|
    (predicate list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  when (funcall predicate element)
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=false end=other count=other key=other|
    (predicate list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (loop for index from start
	  for remaining = rest then (cdr remaining)
	  until (or (atom remaining) (>= index end) (zerop count))
	  for element = (car remaining)
	  when (funcall predicate (funcall key element))
	    do (let ((temp (list element)))
		 (setf (cdr last) temp)
		 (setf last temp))
	  else
	    do (decf count)
	  finally (tail-must-be-proper-list-with-end 'remove list remaining end index)
		  (setf (cdr last) remaining))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=true end=nil count=other key=identity|
    (predicate list start count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall predicate element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=true end=nil count=other key=other|
    (predicate list start count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((end (compute-length-from-remainder 'remove list rest start))
	  (tail '()))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall predicate (funcall key element)))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=true end=other count=other key=identity|
    (predicate list start end count)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall predicate element))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if-not seq-type=list from-end=true end=other count=other key=other|
    (predicate list start end count key)
  (multiple-value-bind (result last rest) (copy-prefix 'remove list start)
    (let ((tail (verify-end-index 'remove list rest start end)))
      (labels ((traverse-list-step-1 (list length)
		 (if (<= length 0)
		     nil
		     (progn (traverse-list-step-1 (cdr list) (1- length))
			    (let ((element (car list)))
			      (if (and (not (funcall predicate (funcall key element)))
				       (plusp count))
				  (decf count) 
				  (push element tail)))))))
	(traverse-list #'traverse-list-step-1 rest (- end start) 1))
      (setf (cdr last) tail))
    (cdr result)))

(defun |remove-if-not seq-type=general-vector count=nil key=identity|
    (predicate vector start end)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=general-vector count=nil key=other|
    (predicate vector start end key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=general-vector from-end=false count=other key=identity|
    (predicate vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=general-vector from-end=false count=other key=other|
    (predicate vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=general-vector from-end=true count=other key=identity|
    (predicate vector start end count)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (aref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=general-vector from-end=true count=other key=other|
    (predicate vector start end count key)
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (aref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-general vector start end bit-vector delete-count)))

;;; For vectors, the technique used is to allocate a bitvector that
;;; has the length of the interval in which elements should be
;;; removed, i.e. end - start.  Elements to keep are then marked with
;;; a 1 in that bitvector, and at the same time, we count the number
;;; of 1s.  Finally, we allocate a vector of the correct size, copy
;;; the prefix of the original vector (before start), the elements of
;;; the original vector marked by a 1 in the bitvector in the interval
;;; between start and end, and the suffix of the original vector
;;; (after end).  This technique has the disadvantage that elements of
;;; the original vector in the interval between start and end have to
;;; be accessed twice; once in order to apply the test to see whether
;;; to mark them in the bitvector, and once more to move them from the
;;; original vector to the result vector.  And of course, the
;;; bitvector has to be manipulated as well.  For very quick
;;; combinations of tests and keys, for instance eq and identity, it
;;; may be faster to apply the test twice; once by going through the
;;; original vector and just counting the number of elements to keep,
;;; and then once more in order to move from the original to the
;;; resulting vector.  That method would save the bitvector
;;; manipulation, but it would access *all* of the elements in the the
;;; interval between start and end twice, not only those that are to
;;; be kept.

(defun |remove-if-not seq-type=simple-vector count=nil key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-vector count=nil key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-vector from-end=false count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-vector from-end=false count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-vector from-end=true count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (svref vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-vector from-end=true count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (svref vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string count=nil key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string count=nil key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string from-end=false count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string from-end=false count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i from start below end
	  until (zerop count)
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string from-end=true count=other key=identity|
    (predicate vector start end count)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (schar vector i))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun |remove-if-not seq-type=simple-string from-end=true count=other key=other|
    (predicate vector start end count key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (let ((bit-vector (make-array (- end start) :element-type 'bit :initial-element 1))
	(delete-count 0))
    (loop for i downfrom (1- end) to start
	  until (zerop count)
	  when (funcall predicate (funcall key (schar vector i)))
	    do (setf (sbit bit-vector (- i start)) 0)
	       (incf delete-count)
	       (decf count))
    (copy-result-simple-string vector start end bit-vector delete-count)))

(defun remove-if-not (predicate sequence &key from-end (start 0) end count key)
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if end
	      (if count
		  (if key
		      (|remove-if-not seq-type=list from-end=true end=other count=other key=other|
		       predicate sequence start end count key)
		      (|remove-if-not seq-type=list from-end=true end=other count=other key=identity|
		       predicate sequence start end count))
		  (if key
		      (|remove-if-not seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if-not seq-type=list end=other count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if key
		      (|remove-if-not seq-type=list from-end=true end=nil count=other key=other|
		       predicate sequence start count key)
		      (|remove-if-not seq-type=list from-end=true end=nil count=other key=identity|
		       predicate sequence start count))
		  (if key
		      (|remove-if-not seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if-not seq-type=list end=other count=nil key=identity|
		       predicate sequence start end))))
	  (if end
	      (if count
		  (if key
		      (|remove-if-not seq-type=list from-end=false end=other count=other key=other|
		       predicate sequence start end count key)
		      (|remove-if-not seq-type=list from-end=false end=other count=other key=identity|
		       predicate sequence start end count))
		  (if key
		      (|remove-if-not seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if-not seq-type=list end=other count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if key
		      (|remove-if-not seq-type=list from-end=false end=nil count=other key=other|
		       predicate sequence start count key)
		      (|remove-if-not seq-type=list from-end=false end=nil count=other key=identity|
		       predicate sequence start count))
		  (if key
		      (|remove-if-not seq-type=list end=other count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if-not seq-type=list end=other count=nil key=identity|
		       predicate sequence start end)))))
      (if (simple-string-p sequence)
	  (if end
	      (if count
		  (if from-end
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=other|
			   predicate sequence start end count key)
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=identity|
			   predicate sequence start end count))
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=other|
			   predicate sequence start end count key)
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=identity|
			   predicate sequence start end count)))
		  (if key
		      (|remove-if-not seq-type=simple-string count=nil key=other|
		       predicate sequence start end key)
		      (|remove-if-not seq-type=simple-string count=nil key=identity|
		       predicate sequence start end)))
	      (if count
		  (if from-end
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=other|
			   predicate sequence start (length sequence) count key)
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=identity|
			   predicate sequence start (length sequence) count))
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=other|
			   predicate sequence start (length sequence) count key)
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=identity|
			   predicate sequence start (length sequence) count)))
		  (if key
		      (|remove-if-not seq-type=simple-string count=nil key=other|
		       predicate sequence start (length sequence) key)
		      (|remove-if-not seq-type=simple-string count=nil key=identity|
		       predicate sequence start (length sequence)))))
	  (if (simple-vector-p sequence)
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=identity|
			       predicate sequence start end count))
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=identity|
			       predicate sequence start end count)))
		      (if key
			  (|remove-if-not seq-type=simple-vector count=nil key=other|
			   predicate sequence start end key)
			  (|remove-if-not seq-type=simple-vector count=nil key=identity|
			   predicate sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=identity|
			       predicate sequence start (length sequence) count))
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=identity|
			       predicate sequence start (length sequence) count)))
		      (if key
			  (|remove-if-not seq-type=simple-vector count=nil key=other|
			   predicate sequence start (length sequence) key)
			  (|remove-if-not seq-type=simple-vector count=nil key=identity|
			   predicate sequence start (length sequence)))))
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=identity|
			       predicate sequence start end count))
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=other|
			       predicate sequence start end count key)
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=identity|
			       predicate sequence start end count)))
		      (if key
			  (|remove-if-not seq-type=general-vector count=nil key=other|
			   predicate sequence start end key)
			  (|remove-if-not seq-type=general-vector count=nil key=identity|
			   predicate sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=identity|
			       predicate sequence start (length sequence) count))
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=other|
			       predicate sequence start (length sequence) count key)
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=identity|
			       predicate sequence start (length sequence) count)))
		      (if key
			  (|remove-if-not seq-type=general-vector count=nil key=other|
			   predicate sequence start (length sequence) key)
			  (|remove-if-not seq-type=general-vector count=nil key=identity|
			   predicate sequence start (length sequence)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function delete

(defun |delete seq-type=list end=nil test=eql count=nil key=identity|
    (item list start)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (eql item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=nil test=eq count=nil key=identity|
    (item list start)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (eq item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=nil test=eql count=nil key=other|
    (item list start key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (eql item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=nil test=eq count=nil key=other|
    (item list start key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (eq item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=other test=eql count=nil key=identity|
    (item list start end)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (eql item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list end=other test=eq count=nil key=identity|
    (item list start end)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (eq item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list end=other test=eql count=nil key=other|
    (item list start end key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (eql item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list end=other test=eq count=nil key=other|
    (item list start end key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (eq item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list end=nil test=other count=nil key=identity|
    (item list start test)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (funcall test item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=nil test=other count=nil key=other|
    (item list start test key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (funcall test item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list end=other test=other count=nil key=identity|
    (item list start end test)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (funcall test item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list end=other test=other count=nil key=other|
    (item list start end test key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (funcall test item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list test-not=other end=nil count=nil key=identity|
    (item list start test-not)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  unless (funcall test-not item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list test-not=other end=nil count=nil key=other|
    (item list start test-not key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  unless (funcall test-not item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list test-not=other end=other count=nil key=identity|
    (item list start end test-not)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  unless (funcall test-not item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list test-not=other end=other count=nil key=other|
    (item list start end test-not key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  unless (funcall test-not item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=eql count=other key=identity|
    (item list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (eql item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=eq count=other key=identity|
    (item list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (eq item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=eql count=other key=other|
    (item list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (eql item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=eq count=other key=other|
    (item list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (eq item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=eql count=other key=identity|
    (item list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (eql item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=eq count=other key=identity|
    (item list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (eq item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=eql count=other key=other|
    (item list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (eql item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=eq count=other key=other|
    (item list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (eq item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=other count=other key=identity|
    (item list start test count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (funcall test item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=nil test=other count=other key=other|
    (item list start test count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (funcall test item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=other count=other key=identity|
    (item list start end test count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (funcall test item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false end=other test=other count=other key=other|
    (item list start end test count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (funcall test item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false test-not=other end=nil count=other key=identity|
    (item list start test-not count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  unless (funcall test-not item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false test-not=other end=nil count=other key=other|
    (item list start test-not count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  unless (funcall test-not item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete seq-type=list from-end=false test-not=other end=other count=other key=identity|
    (item list start end test-not count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  unless (funcall test-not item (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=false test-not=other end=other count=other key=other|
    (item list start end test-not count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  unless (funcall test-not item (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=eql count=other key=identity|
    (item list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eql item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=eq count=other key=identity|
    (item list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eq item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=eql count=other key=other|
    (item list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eql item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=eq count=other key=other|
    (item list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eq item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=eql count=other key=identity|
    (item list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eql item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=eq count=other key=identity|
    (item list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eq item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=eql count=other key=other|
    (item list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eql item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=eq count=other key=other|
    (item list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (eq item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=other count=other key=identity|
    (item list start test count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=nil test=other count=other key=other|
    (item list start test count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=other count=other key=identity|
    (item list start end test count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true end=other test=other count=other key=other|
    (item list start end test count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true test-not=other end=nil count=other key=identity|
    (item list start test-not count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true test-not=other end=nil count=other key=other|
    (item list start test-not count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true test-not=other end=other count=other key=identity|
    (item list start end test-not count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not item (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete seq-type=list from-end=true test-not=other end=other count=other key=other|
    (item list start end test-not count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not item (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

;;; For now, use the corresponding remove functions on sequences

(defun delete (item sequence
	       &key
	       from-end
	       (test nil test-p)
	       (test-not nil test-not-p)
	       (start 0)
	       end
	       count
	       key)
  (when (and test-p test-not-p)
    (error 'both-test-and-test-not-given
	   :name 'delete))
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true end=other test=eq count=other key=other|
			       item sequence start end count key)
			      (|delete seq-type=list from-end=true end=other test=eq count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|delete seq-type=list end=other test=eq count=nil key=other|
			       item sequence start end key)
			      (|delete seq-type=list end=other test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true end=nil test=eq count=other key=other|
			       item sequence start count key)
			      (|delete seq-type=list from-end=true end=nil test=eq count=other key=identity|
			       item sequence start count))
			  (if key
			      (|delete seq-type=list end=nil test=eq count=nil key=other|
			       item sequence start key)
			      (|delete seq-type=list end=nil test=eq count=nil key=identity|
			       item sequence start))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if key
				  (|delete seq-type=list from-end=true end=other test=eql count=other key=other|
				   item sequence start end count key)
				  (|delete seq-type=list from-end=true end=other test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|delete seq-type=list end=other test=eql count=nil key=other|
				   item sequence start end key)
				  (|delete seq-type=list end=other test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if key
				  (|delete seq-type=list from-end=true end=nil test=eql count=other key=other|
				   item sequence start count key)
				  (|delete seq-type=list from-end=true end=nil test=eql count=other key=identity|
				   item sequence start count))
			      (if key
				  (|delete seq-type=list end=nil test=eql count=nil key=other|
				   item sequence start key)
				  (|delete seq-type=list end=nil test=eql count=nil key=identity|
				   item sequence start))))
		      (if end
			  (if count
			      (if key
				  (|delete seq-type=list from-end=true end=other test=other count=other key=other|
				   item sequence start end test count key)
				  (|delete seq-type=list from-end=true end=other test=other count=other key=identity|
				   item sequence start end test count))
			      (if key
				  (|delete seq-type=list end=other test=other count=nil key=other|
				   item sequence start end test key)
				  (|delete seq-type=list end=other test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if key
				  (|delete seq-type=list from-end=true end=nil test=other count=other key=other|
				   item sequence start test count key)
				  (|delete seq-type=list from-end=true end=nil test=other count=other key=identity|
				   item sequence start test count))
			      (if key
				  (|delete seq-type=list end=nil test=other count=nil key=other|
				   item sequence start test key)
				  (|delete seq-type=list end=nil test=other count=nil key=identity|
				   item sequence start test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true test-not=other end=other count=other key=other|
			       item sequence start end test-not count key)
			      (|delete seq-type=list from-end=true test-not=other end=other count=other key=identity|
			       item sequence start end test-not count))
			  (if key
			      (|delete seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|delete seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true test-not=other end=nil count=other key=other|
			       item sequence start test-not count key)
			      (|delete seq-type=list from-end=true test-not=other end=nil count=other key=identity|
			       item sequence start test-not count))
			  (if key
			      (|delete seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|delete seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not))))
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true end=other test=eql count=other key=other|
			       item sequence start end count key)
			      (|delete seq-type=list from-end=true end=other test=eql count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|delete seq-type=list end=other test=eql count=nil key=other|
			       item sequence start end key)
			      (|delete seq-type=list end=other test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=true end=nil test=eql count=other key=other|
			       item sequence start count key)
			      (|delete seq-type=list from-end=true end=nil test=eql count=other key=identity|
			       item sequence start count))
			  (if key
			      (|delete seq-type=list end=nil test=eql count=nil key=other|
			       item sequence start key)
			      (|delete seq-type=list end=nil test=eql count=nil key=identity|
			       item sequence start))))))
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false end=other test=eq count=other key=other|
			       item sequence start end count key)
			      (|delete seq-type=list from-end=false end=other test=eq count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|delete seq-type=list end=other test=eq count=nil key=other|
			       item sequence start end key)
			      (|delete seq-type=list end=other test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false end=nil test=eq count=other key=other|
			       item sequence start count key)
			      (|delete seq-type=list from-end=false end=nil test=eq count=other key=identity|
			       item sequence start count))
			  (if key
			      (|delete seq-type=list end=nil test=eq count=nil key=other|
			       item sequence start key)
			      (|delete seq-type=list end=nil test=eq count=nil key=identity|
			       item sequence start))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if key
				  (|delete seq-type=list from-end=false end=other test=eql count=other key=other|
				   item sequence start end count key)
				  (|delete seq-type=list from-end=false end=other test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|delete seq-type=list end=other test=eql count=nil key=other|
				   item sequence start end key)
				  (|delete seq-type=list end=other test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if key
				  (|delete seq-type=list from-end=false end=nil test=eql count=other key=other|
				   item sequence start count key)
				  (|delete seq-type=list from-end=false end=nil test=eql count=other key=identity|
				   item sequence start count))
			      (if key
				  (|delete seq-type=list end=nil test=eql count=nil key=other|
				   item sequence start key)
				  (|delete seq-type=list end=nil test=eql count=nil key=identity|
				   item sequence start))))
		      (if end
			  (if count
			      (if key
				  (|delete seq-type=list from-end=false end=other test=other count=other key=other|
				   item sequence start end test count key)
				  (|delete seq-type=list from-end=false end=other test=other count=other key=identity|
				   item sequence start end test count))
			      (if key
				  (|delete seq-type=list end=other test=other count=nil key=other|
				   item sequence start end test key)
				  (|delete seq-type=list end=other test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if key
				  (|delete seq-type=list from-end=false end=nil test=other count=other key=other|
				   item sequence start test count key)
				  (|delete seq-type=list from-end=false end=nil test=other count=other key=identity|
				   item sequence start test count))
			      (if key
				  (|delete seq-type=list end=nil test=other count=nil key=other|
				   item sequence start test key)
				  (|delete seq-type=list end=nil test=other count=nil key=identity|
				   item sequence start test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false test-not=other end=other count=other key=other|
			       item sequence start end test-not count key)
			      (|delete seq-type=list from-end=false test-not=other end=other count=other key=identity|
			       item sequence start end test-not count))
			  (if key
			      (|delete seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|delete seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false test-not=other end=nil count=other key=other|
			       item sequence start test-not count key)
			      (|delete seq-type=list from-end=false test-not=other end=nil count=other key=identity|
			       item sequence start test-not count))
			  (if key
			      (|delete seq-type=list test-not=other end=other count=nil key=other|
			       item sequence start end test-not key)
			      (|delete seq-type=list test-not=other end=other count=nil key=identity|
			       item sequence start end test-not))))
		  (if end
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false end=other test=eql count=other key=other|
			       item sequence start end count key)
			      (|delete seq-type=list from-end=false end=other test=eql count=other key=identity|
			       item sequence start end count))
			  (if key
			      (|delete seq-type=list end=other test=eql count=nil key=other|
			       item sequence start end key)
			      (|delete seq-type=list end=other test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if key
			      (|delete seq-type=list from-end=false end=nil test=eql count=other key=other|
			       item sequence start count key)
			      (|delete seq-type=list from-end=false end=nil test=eql count=other key=identity|
			       item sequence start count))
			  (if key
			      (|delete seq-type=list end=nil test=eql count=nil key=other|
			       item sequence start key)
			      (|delete seq-type=list end=nil test=eql count=nil key=identity|
			       item sequence start)))))))
      (if (simple-string-p sequence)
	  (if test-p
	      (if (or (eq test 'eq) (eq test #'eq))
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=identity|
				   item sequence start end count)))
			  (if key
			      (|remove seq-type=simple-string test=eq count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=simple-string test=eq count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=true test=eq count=other key=identity|
				   item sequence start (length sequence) count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=false test=eq count=other key=identity|
				   item sequence start (length sequence) count)))
			  (if key
			      (|remove seq-type=simple-string test=eq count=nil key=other|
			       item sequence start (length sequence) key)
			      (|remove seq-type=simple-string test=eq count=nil key=identity|
			       item sequence start (length sequence)))))
		  (if (or (eq test 'eql) (eq test #'eql))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-string test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-string test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-string test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-string test=eql count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=other count=other key=other|
				       item sequence start end test count key)
				      (|remove seq-type=simple-string from-end=true test=other count=other key=identity|
				       item sequence start end test count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=other count=other key=other|
				       item sequence start end test count key)
				      (|remove seq-type=simple-string from-end=false test=other count=other key=identity|
				       item sequence start end test count)))
			      (if key
				  (|remove seq-type=simple-string test=other count=nil key=other|
				   item sequence start end test key)
				  (|remove seq-type=simple-string test=other count=nil key=identity|
				   item sequence start end test)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-string from-end=true test=other count=other key=other|
				       item sequence start (length sequence) test count key)
				      (|remove seq-type=simple-string from-end=true test=other count=other key=identity|
				       item sequence start (length sequence) test count))
				  (if key
				      (|remove seq-type=simple-string from-end=false test=other count=other key=other|
				       item sequence start (length sequence) test count key)
				      (|remove seq-type=simple-string from-end=false test=other count=other key=identity|
				       item sequence start (length sequence) test count)))
			      (if key
				  (|remove seq-type=simple-string test=other count=nil key=other|
				   item sequence start (length sequence) test key)
				  (|remove seq-type=simple-string test=other count=nil key=identity|
				   item sequence start (length sequence) test))))))
	      (if test-not-p
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=other|
				   item sequence start end test-not count key)
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=identity|
				   item sequence start end test-not count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=other|
				   item sequence start end test-not count key)
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=identity|
				   item sequence start end test-not count)))
			  (if key
			      (|remove seq-type=simple-string test-not=other count=nil key=other|
			       item sequence start end test-not key)
			      (|remove seq-type=simple-string test-not=other count=nil key=identity|
			       item sequence start end test-not)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=other|
				   item sequence start (length sequence) test-not count key)
				  (|remove seq-type=simple-string from-end=true test-not=other count=other key=identity|
				   item sequence start (length sequence) test-not count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=other|
				   item sequence start (length sequence) test-not count key)
				  (|remove seq-type=simple-string from-end=false test-not=other count=other key=identity|
				   item sequence start (length sequence) test-not count)))
			  (if key
			      (|remove seq-type=simple-string test-not=other count=nil key=other|
			       item sequence start (length sequence) test-not key)
			      (|remove seq-type=simple-string test-not=other count=nil key=identity|
			       item sequence start (length sequence) test-not))))
		  (if end
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				   item sequence start end count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				   item sequence start end count key)
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				   item sequence start end count)))
			  (if key
			      (|remove seq-type=simple-string test=eql count=nil key=other|
			       item sequence start end key)
			      (|remove seq-type=simple-string test=eql count=nil key=identity|
			       item sequence start end)))
		      (if count
			  (if from-end
			      (if key
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=true test=eql count=other key=identity|
				   item sequence start (length sequence) count))
			      (if key
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=other|
				   item sequence start (length sequence) count key)
				  (|remove seq-type=simple-string from-end=false test=eql count=other key=identity|
				   item sequence start (length sequence) count)))
			  (if key
			      (|remove seq-type=simple-string test=eql count=nil key=other|
			       item sequence start (length sequence) key)
			      (|remove seq-type=simple-string test=eql count=nil key=identity|
			       item sequence start (length sequence)))))))
	  (if (simple-vector-p sequence)
	      (if test-p
		  (if (or (eq test 'eq) (eq test #'eq))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-vector test=eq count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-vector test=eq count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=true test=eq count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=false test=eq count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-vector test=eq count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-vector test=eq count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if (or (eq test 'eql) (eq test #'eql))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
					   item sequence start end count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
					   item sequence start end count)))
				  (if key
				      (|remove seq-type=simple-vector test=eql count=nil key=other|
				       item sequence start end key)
				      (|remove seq-type=simple-vector test=eql count=nil key=identity|
				       item sequence start end)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
					   item sequence start (length sequence) count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
					   item sequence start (length sequence) count)))
				  (if key
				      (|remove seq-type=simple-vector test=eql count=nil key=other|
				       item sequence start (length sequence) key)
				      (|remove seq-type=simple-vector test=eql count=nil key=identity|
				       item sequence start (length sequence)))))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=identity|
					   item sequence start end test count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=identity|
					   item sequence start end test count)))
				  (if key
				      (|remove seq-type=simple-vector test=other count=nil key=other|
				       item sequence start end test key)
				      (|remove seq-type=simple-vector test=other count=nil key=identity|
				       item sequence start end test)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=simple-vector from-end=true test=other count=other key=identity|
					   item sequence start (length sequence) test count))
				      (if key
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=simple-vector from-end=false test=other count=other key=identity|
					   item sequence start (length sequence) test count)))
				  (if key
				      (|remove seq-type=simple-vector test=other count=nil key=other|
				       item sequence start (length sequence) test key)
				      (|remove seq-type=simple-vector test=other count=nil key=identity|
				       item sequence start (length sequence) test))))))
		  (if test-not-p
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=identity|
				       item sequence start end test-not count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=identity|
				       item sequence start end test-not count)))
			      (if key
				  (|remove seq-type=simple-vector test-not=other count=nil key=other|
				   item sequence start end test-not key)
				  (|remove seq-type=simple-vector test-not=other count=nil key=identity|
				   item sequence start end test-not)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=simple-vector from-end=true test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=simple-vector from-end=false test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count)))
			      (if key
				  (|remove seq-type=simple-vector test-not=other count=nil key=other|
				   item sequence start (length sequence) test-not key)
				  (|remove seq-type=simple-vector test-not=other count=nil key=identity|
				   item sequence start (length sequence) test-not))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=simple-vector test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=simple-vector test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=simple-vector from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=simple-vector test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=simple-vector test=eql count=nil key=identity|
				   item sequence start (length sequence)))))))
	      (if test-p
		  (if (or (eq test 'eq) (eq test #'eq))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=general-vector test=eq count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=general-vector test=eq count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=true test=eq count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=false test=eq count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=general-vector test=eq count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=general-vector test=eq count=nil key=identity|
				   item sequence start (length sequence)))))
		      (if (or (eq test 'eql) (eq test #'eql))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
					   item sequence start end count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
					   item sequence start end count key)
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
					   item sequence start end count)))
				  (if key
				      (|remove seq-type=general-vector test=eql count=nil key=other|
				       item sequence start end key)
				      (|remove seq-type=general-vector test=eql count=nil key=identity|
				       item sequence start end)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
					   item sequence start (length sequence) count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
					   item sequence start (length sequence) count key)
					  (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
					   item sequence start (length sequence) count)))
				  (if key
				      (|remove seq-type=general-vector test=eql count=nil key=other|
				       item sequence start (length sequence) key)
				      (|remove seq-type=general-vector test=eql count=nil key=identity|
				       item sequence start (length sequence)))))
			  (if end
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=general-vector from-end=true test=other count=other key=identity|
					   item sequence start end test count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=other count=other key=other|
					   item sequence start end test count key)
					  (|remove seq-type=general-vector from-end=false test=other count=other key=identity|
					   item sequence start end test count)))
				  (if key
				      (|remove seq-type=general-vector test=other count=nil key=other|
				       item sequence start end test key)
				      (|remove seq-type=general-vector test=other count=nil key=identity|
				       item sequence start end test)))
			      (if count
				  (if from-end
				      (if key
					  (|remove seq-type=general-vector from-end=true test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=general-vector from-end=true test=other count=other key=identity|
					   item sequence start (length sequence) test count))
				      (if key
					  (|remove seq-type=general-vector from-end=false test=other count=other key=other|
					   item sequence start (length sequence) test count key)
					  (|remove seq-type=general-vector from-end=false test=other count=other key=identity|
					   item sequence start (length sequence) test count)))
				  (if key
				      (|remove seq-type=general-vector test=other count=nil key=other|
				       item sequence start (length sequence) test key)
				      (|remove seq-type=general-vector test=other count=nil key=identity|
				       item sequence start (length sequence) test))))))
		  (if test-not-p
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=identity|
				       item sequence start end test-not count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=other|
				       item sequence start end test-not count key)
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=identity|
				       item sequence start end test-not count)))
			      (if key
				  (|remove seq-type=general-vector test-not=other count=nil key=other|
				   item sequence start end test-not key)
				  (|remove seq-type=general-vector test-not=other count=nil key=identity|
				   item sequence start end test-not)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=general-vector from-end=true test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=other|
				       item sequence start (length sequence) test-not count key)
				      (|remove seq-type=general-vector from-end=false test-not=other count=other key=identity|
				       item sequence start (length sequence) test-not count)))
			      (if key
				  (|remove seq-type=general-vector test-not=other count=nil key=other|
				   item sequence start (length sequence) test-not key)
				  (|remove seq-type=general-vector test-not=other count=nil key=identity|
				   item sequence start (length sequence) test-not))))
		      (if end
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
				       item sequence start end count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
				       item sequence start end count key)
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
				       item sequence start end count)))
			      (if key
				  (|remove seq-type=general-vector test=eql count=nil key=other|
				   item sequence start end key)
				  (|remove seq-type=general-vector test=eql count=nil key=identity|
				   item sequence start end)))
			  (if count
			      (if from-end
				  (if key
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=true test=eql count=other key=identity|
				       item sequence start (length sequence) count))
				  (if key
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=other|
				       item sequence start (length sequence) count key)
				      (|remove seq-type=general-vector from-end=false test=eql count=other key=identity|
				       item sequence start (length sequence) count)))
			      (if key
				  (|remove seq-type=general-vector test=eql count=nil key=other|
				   item sequence start (length sequence) key)
				  (|remove seq-type=general-vector test=eql count=nil key=identity|
				   item sequence start (length sequence)))))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function delete-if

(defun |delete-if seq-type=list end=nil count=nil key=identity|
    (test list start)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (funcall test (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if seq-type=list end=nil count=nil key=other|
    (test list start key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  when (funcall test (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if seq-type=list end=other count=nil key=identity|
    (test list start end)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (funcall test (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if seq-type=list end=other count=nil key=other|
    (test list start end key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  when (funcall test (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if seq-type=list from-end=false end=nil count=other key=identity|
    (test list count start)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (funcall test (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if seq-type=list from-end=false end=nil count=other key=other|
    (test list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  when (funcall test (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if seq-type=list from-end=false end=other count=other key=identity|
    (test list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (funcall test (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if seq-type=list from-end=false end=other count=other key=other|
    (test list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  when (funcall test (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if seq-type=list from-end=true end=nil count=other key=identity|
    (test list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if seq-type=list from-end=true end=nil count=other key=other|
    (test list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if seq-type=list from-end=true end=other count=other key=identity|
    (test list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if seq-type=list from-end=true end=other count=other key=other|
    (test list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  unless (funcall test (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun delete-if (test sequence &key from-end (start 0) end count key)
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if end
	      (if count
		  (if key
		      (|delete-if seq-type=list from-end=true end=other count=other key=other|
		       test sequence start end count key)
		      (|delete-if seq-type=list from-end=true end=other count=other key=identity|
		       test sequence start end count))
		  (if key
		      (|delete-if seq-type=list end=other count=nil key=other|
		       test sequence start end key)
		      (|delete-if seq-type=list end=other count=nil key=identity|
		       test sequence start end)))
	      (if count
		  (if key
		      (|delete-if seq-type=list from-end=true end=nil count=other key=other|
		       test sequence start count key)
		      (|delete-if seq-type=list from-end=true end=nil count=other key=identity|
		       test sequence start count))
		  (if key
		      (|delete-if seq-type=list end=nil count=nil key=other|
		       test sequence start key)
		      (|delete-if seq-type=list end=nil count=nil key=identity|
		       test sequence start))))
	  (if end
	      (if count
		  (if key
		      (|delete-if seq-type=list from-end=false end=other count=other key=other|
		       test sequence start end count key)
		      (|delete-if seq-type=list from-end=false end=other count=other key=identity|
		       test sequence start end count))
		  (if key
		      (|delete-if seq-type=list end=other count=nil key=other|
		       test sequence start end key)
		      (|delete-if seq-type=list end=other count=nil key=identity|
		       test sequence start end)))
	      (if count
		  (if key
		      (|delete-if seq-type=list from-end=false end=nil count=other key=other|
		       test sequence start count key)
		      (|delete-if seq-type=list from-end=false end=nil count=other key=identity|
		       test sequence start count))
		  (if key
		      (|delete-if seq-type=list end=nil count=nil key=other|
		       test sequence start key)
		      (|delete-if seq-type=list end=nil count=nil key=identity|
		       test sequence start)))))
      (if (simple-string-p sequence)
	  (if end
	      (if count
		  (if from-end
		      (if key
			  (|remove-if seq-type=simple-string from-end=true count=other key=other|
			   test sequence start end count key)
			  (|remove-if seq-type=simple-string from-end=true count=other key=identity|
			   test sequence start end count))
		      (if key
			  (|remove-if seq-type=simple-string from-end=false count=other key=other|
			   test sequence start end count key)
			  (|remove-if seq-type=simple-string from-end=false count=other key=identity|
			   test sequence start end count)))
		  (if key
		      (|remove-if seq-type=simple-string count=nil key=other|
		       test sequence start end key)
		      (|remove-if seq-type=simple-string count=nil key=identity|
		       test sequence start end)))
	      (if count
		  (if from-end
		      (if key
			  (|remove-if seq-type=simple-string from-end=true count=other key=other|
			   test sequence start (length sequence) count key)
			  (|remove-if seq-type=simple-string from-end=true count=other key=identity|
			   test sequence start (length sequence) count))
		      (if key
			  (|remove-if seq-type=simple-string from-end=false count=other key=other|
			   test sequence start (length sequence) count key)
			  (|remove-if seq-type=simple-string from-end=false count=other key=identity|
			   test sequence start (length sequence) count)))
		  (if key
		      (|remove-if seq-type=simple-string count=nil key=other|
		       test sequence start (length sequence) key)
		      (|remove-if seq-type=simple-string count=nil key=identity|
		       test sequence start (length sequence)))))
	  (if (simple-vector-p sequence)
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=simple-vector from-end=true count=other key=other|
			       test sequence start end count key)
			      (|remove-if seq-type=simple-vector from-end=true count=other key=identity|
			       test sequence start end count))
			  (if key
			      (|remove-if seq-type=simple-vector from-end=false count=other key=other|
			       test sequence start end count key)
			      (|remove-if seq-type=simple-vector from-end=false count=other key=identity|
			       test sequence start end count)))
		      (if key
			  (|remove-if seq-type=simple-vector count=nil key=other|
			   test sequence start end key)
			  (|remove-if seq-type=simple-vector count=nil key=identity|
			   test sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=simple-vector from-end=true count=other key=other|
			       test sequence start (length sequence) count key)
			      (|remove-if seq-type=simple-vector from-end=true count=other key=identity|
			       test sequence start (length sequence) count))
			  (if key
			      (|remove-if seq-type=simple-vector from-end=false count=other key=other|
			       test sequence start (length sequence) count key)
			      (|remove-if seq-type=simple-vector from-end=false count=other key=identity|
			       test sequence start (length sequence) count)))
		      (if key
			  (|remove-if seq-type=simple-vector count=nil key=other|
			   test sequence start (length sequence) key)
			  (|remove-if seq-type=simple-vector count=nil key=identity|
			   test sequence start (length sequence)))))
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=general-vector from-end=true count=other key=other|
			       test sequence start end count key)
			      (|remove-if seq-type=general-vector from-end=true count=other key=identity|
			       test sequence start end count))
			  (if key
			      (|remove-if seq-type=general-vector from-end=false count=other key=other|
			       test sequence start end count key)
			      (|remove-if seq-type=general-vector from-end=false count=other key=identity|
			       test sequence start end count)))
		      (if key
			  (|remove-if seq-type=general-vector count=nil key=other|
			   test sequence start end key)
			  (|remove-if seq-type=general-vector count=nil key=identity|
			   test sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if seq-type=general-vector from-end=true count=other key=other|
			       test sequence start (length sequence) count key)
			      (|remove-if seq-type=general-vector from-end=true count=other key=identity|
			       test sequence start (length sequence) count))
			  (if key
			      (|remove-if seq-type=general-vector from-end=false count=other key=other|
			       test sequence start (length sequence) count key)
			      (|remove-if seq-type=general-vector from-end=false count=other key=identity|
			       test sequence start (length sequence) count)))
		      (if key
			  (|remove-if seq-type=general-vector count=nil key=other|
			   test sequence start (length sequence) key)
			  (|remove-if seq-type=general-vector count=nil key=identity|
			   test sequence start (length sequence)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function delete-if-not

(defun |delete-if-not seq-type=list end=nil count=nil key=identity|
    (test-not list start)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  unless (funcall test-not (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if-not seq-type=list end=nil count=nil key=other|
    (test-not list start key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  unless (funcall test-not (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if-not seq-type=list end=other count=nil key=identity|
    (test-not list start end)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  unless (funcall test-not (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if-not seq-type=list end=other count=nil key=other|
    (test-not list start end key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop end-start)
	  unless (funcall test-not (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=false end=nil count=other key=identity|
    (test-not list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  unless (funcall test-not (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=false end=nil count=other key=other|
    (test-not list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  unless (funcall test-not (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current)))
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=false end=other count=other key=identity|
    (test-not list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  unless (funcall test-not (car current))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=false end=other count=other key=other|
    (test-not list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Loop through the elements checking whether
    ;; they pass the test.
    ;; Loop invariant: trail points to the cell
    ;; imidiately preceding that pointed to by current.
    (loop until (null current)
	  until (zerop count)
	  until (zerop end-start)
	  unless (funcall test-not (funcall key (car current)))
	    do (setf current (cdr current))
	       (setf (cdr trail) current)
	       (decf count)
	  else
	    do (setf trail current)
	       (setf current (cdr current))
	  do (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=true end=nil count=other key=identity|
    (test-not list start count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=true end=nil count=other key=other|
    (test-not list start count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '()))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp)))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=true end=other count=other key=identity|
    (test-not list start end count)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not (car reversed-middle))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun |delete-if-not seq-type=list from-end=true end=other count=other key=other|
    (test-not list start end count key)
  (let* ((result (cons nil list))
	 (start-bis start)
	 (trail result)
	 (current list)
	 (reversed-middle '())
	 (end-start (- end start)))
    ;; First skip a prefix indicated by start
    (loop repeat start
	  until (null current)
	  do (setf trail current
		   current (cdr current))
	     (decf start-bis))
    ;; If we reached the end of the list before start-bis
    ;; became zero, then start is beyond the end of the
    ;; list.
    (when (plusp start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))))
    ;; Now, reverse the sublist between start and end
    ;; and put the result in reversed-middle.
    (loop until (null current)
	  until (zerop end-start)
	  do (let ((temp (cdr current)))
	       (setf (cdr current) reversed-middle)
	       (setf reversed-middle current)
	       (setf current temp))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(+ start (- end end-start)))
	     :in-sequence list))
    ;; The variable current now points to a tail
    ;; delimited by end, so we don't touch it.
    ;; Loop through the elements of reversed middle
    ;; skipping the ones to delete, and putting the others
    ;; back in the original order on the front of the tail
    ;; pointed to by current.
    (loop until (null reversed-middle)
	  until (zerop count)
	  when (funcall test-not (funcall key (car reversed-middle)))
	    do (let ((temp (cdr reversed-middle)))
		 (setf (cdr reversed-middle) current)
		 (setf current reversed-middle)
		 (setf reversed-middle temp))
	  else
	    do (setf reversed-middle (cdr reversed-middle))
	       (decf count))
    ;; There might be remaining elements on reversed-middle
    ;; that weren't deleted because we reached the count.
    ;; Copy them as before but without testing.
    (loop until (null reversed-middle)
	  do (let ((temp (cdr reversed-middle)))
	       (setf (cdr reversed-middle) current)
	       (setf current reversed-middle)
	       (setf reversed-middle temp)))
    ;; Finally, we are ready to connect the prefix pointed to
    ;; by trail to the remaining list pointed to by current.
    (setf (cdr trail) current)
    (cdr result)))

(defun delete-if-not (test-not sequence &key from-end (start 0) end count key)
  ;; FIXME test if it is a sequence at all.
  (if (listp sequence)
      (if from-end
	  (if end
	      (if count
		  (if key
		      (|delete-if-not seq-type=list from-end=true end=other count=other key=other|
		       test-not sequence start end count key)
		      (|delete-if-not seq-type=list from-end=true end=other count=other key=identity|
		       test-not sequence start end count))
		  (if key
		      (|delete-if-not seq-type=list end=other count=nil key=other|
		       test-not sequence start end key)
		      (|delete-if-not seq-type=list end=other count=nil key=identity|
		       test-not sequence start end)))
	      (if count
		  (if key
		      (|delete-if-not seq-type=list from-end=true end=nil count=other key=other|
		       test-not sequence start count key)
		      (|delete-if-not seq-type=list from-end=true end=nil count=other key=identity|
		       test-not sequence start count))
		  (if key
		      (|delete-if-not seq-type=list end=other count=nil key=other|
		       test-not sequence start end key)
		      (|delete-if-not seq-type=list end=other count=nil key=identity|
		       test-not sequence start end))))
	  (if end
	      (if count
		  (if key
		      (|delete-if-not seq-type=list from-end=false end=other count=other key=other|
		       test-not sequence start end count key)
		      (|delete-if-not seq-type=list from-end=false end=other count=other key=identity|
		       test-not sequence start end count))
		  (if key
		      (|delete-if-not seq-type=list end=other count=nil key=other|
		       test-not sequence start end key)
		      (|delete-if-not seq-type=list end=other count=nil key=identity|
		       test-not sequence start end)))
	      (if count
		  (if key
		      (|delete-if-not seq-type=list from-end=false end=nil count=other key=other|
		       test-not sequence start count key)
		      (|delete-if-not seq-type=list from-end=false end=nil count=other key=identity|
		       test-not sequence start count))
		  (if key
		      (|delete-if-not seq-type=list end=other count=nil key=other|
		       test-not sequence start end key)
		      (|delete-if-not seq-type=list end=other count=nil key=identity|
		       test-not sequence start end)))))
      (if (simple-string-p sequence)
	  (if end
	      (if count
		  (if from-end
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=other|
			   test-not sequence start end count key)
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=identity|
			   test-not sequence start end count))
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=other|
			   test-not sequence start end count key)
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=identity|
			   test-not sequence start end count)))
		  (if key
		      (|remove-if-not seq-type=simple-string count=nil key=other|
		       test-not sequence start end key)
		      (|remove-if-not seq-type=simple-string count=nil key=identity|
		       test-not sequence start end)))
	      (if count
		  (if from-end
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=other|
			   test-not sequence start (length sequence) count key)
			  (|remove-if-not seq-type=simple-string from-end=true count=other key=identity|
			   test-not sequence start (length sequence) count))
		      (if key
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=other|
			   test-not sequence start (length sequence) count key)
			  (|remove-if-not seq-type=simple-string from-end=false count=other key=identity|
			   test-not sequence start (length sequence) count)))
		  (if key
		      (|remove-if-not seq-type=simple-string count=nil key=other|
		       test-not sequence start (length sequence) key)
		      (|remove-if-not seq-type=simple-string count=nil key=identity|
		       test-not sequence start (length sequence)))))
	  (if (simple-vector-p sequence)
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=other|
			       test-not sequence start end count key)
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=identity|
			       test-not sequence start end count))
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=other|
			       test-not sequence start end count key)
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=identity|
			       test-not sequence start end count)))
		      (if key
			  (|remove-if-not seq-type=simple-vector count=nil key=other|
			   test-not sequence start end key)
			  (|remove-if-not seq-type=simple-vector count=nil key=identity|
			   test-not sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=other|
			       test-not sequence start (length sequence) count key)
			      (|remove-if-not seq-type=simple-vector from-end=true count=other key=identity|
			       test-not sequence start (length sequence) count))
			  (if key
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=other|
			       test-not sequence start (length sequence) count key)
			      (|remove-if-not seq-type=simple-vector from-end=false count=other key=identity|
			       test-not sequence start (length sequence) count)))
		      (if key
			  (|remove-if-not seq-type=simple-vector count=nil key=other|
			   test-not sequence start (length sequence) key)
			  (|remove-if-not seq-type=simple-vector count=nil key=identity|
			   test-not sequence start (length sequence)))))
	      (if end
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=other|
			       test-not sequence start end count key)
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=identity|
			       test-not sequence start end count))
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=other|
			       test-not sequence start end count key)
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=identity|
			       test-not sequence start end count)))
		      (if key
			  (|remove-if-not seq-type=general-vector count=nil key=other|
			   test-not sequence start end key)
			  (|remove-if-not seq-type=general-vector count=nil key=identity|
			   test-not sequence start end)))
		  (if count
		      (if from-end
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=other|
			       test-not sequence start (length sequence) count key)
			      (|remove-if-not seq-type=general-vector from-end=true count=other key=identity|
			       test-not sequence start (length sequence) count))
			  (if key
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=other|
			       test-not sequence start (length sequence) count key)
			      (|remove-if-not seq-type=general-vector from-end=false count=other key=identity|
			       test-not sequence start (length sequence) count)))
		      (if key
			  (|remove-if-not seq-type=general-vector count=nil key=other|
			   test-not sequence start (length sequence) key)
			  (|remove-if-not seq-type=general-vector count=nil key=identity|
			   test-not sequence start (length sequence)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function copy-seq

;;; This code is the same as in the "small" version of this module.
;;; We need to figure out a way of factoring out common code.

;;; We test for circular lists.
;;; We can afford to do this because the cost is small compared to
;;; the cost of allocating and initializing cons cells.
;;; Furthermore, this is a good idea, because either way, we fail
;;; on circular lists, so we might as well fail with an error message. 

;;; Break out the core of copy-seq into an auxiliary function
;;; that can be used by other functions in this module.

(defun copy-seq-aux (client sequence)
  (cond ((vectorp sequence)
	 (let ((result (make-array (length sequence)
				   :element-type (array-element-type sequence))))
	   (loop for i from 0 below (length sequence)
		 do (setf (aref result i) (aref sequence i)))
	   result))
	((null sequence)
	 '())
	((atom sequence)
	 (error 'must-be-sequence
		:name client
		:datum sequence))
	(t
	 ;; The sequence is a non-empty list.
	 (let* ((fast (cdr sequence))
		(slow sequence)
		(result (cons (car sequence) nil))
		(last result))
	   (loop until (or (eq slow fast) (atom fast))
		 do (setf (cdr last) (cons (pop fast) nil)
			  last (cdr last))
		 until (atom fast)
		 do (setf (cdr last) (cons (pop fast) nil)
			  last (cdr last)
			  slow (cdr slow)))
	   (cond ((null fast)
		  result)
		 (t
		  (error 'must-be-proper-list
			 :name client
			 :datum sequence)))))))

(defun copy-seq (sequence)
  (copy-seq-aux 'copy-seq sequence))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Accessor elt

(defun elt (sequence index)
  (unless (typep index 'unsigned-byte)
    (error 'invalid-sequence-index
	   :datum index
	   :expected-type '(integer 0)
	   :in-sequence sequence))
  (if (listp sequence)
      (loop with list = sequence
	    with save-index = index
	    until (atom list)
	    until (zerop index)
	    do (setf list (cdr list))
	       (decf save-index)
	    finally (cond ((null list)
			   (error 'invalid-sequence-index
				  :name 'elt
				  :datum index
				  :expected-type `(integer 0 ,(- index save-index))
				  :in-sequence sequence))
			  ((atom list)
			   (error 'must-be-proper-list
				  :name 'elt
				  :datum sequence
				  :expected-type 'list))
			  (t
			   (return (car list)))))
      (if (>= index (length sequence))
	  (error 'invalid-sequence-index
		 :name 'elt
		 :datum index
		 :expected-type `(integer 0 ,(1- (length sequence)))
		 :in-sequence sequence)
	  (aref sequence index))))

(defun (setf elt) (new-object sequence index)
  (unless (typep index 'unsigned-byte)
    (error 'invalid-sequence-index
	   :datum index
	   :expected-type '(integer 0)
	   :in-sequence sequence))
  (if (listp sequence)
      (loop with list = sequence
	    with save-index = index
	    until (atom list)
	    until (zerop index)
	    do (setf list (cdr list))
	       (decf save-index)
	    finally (cond ((null list)
			   (error 'invalid-sequence-index
				  :name 'elt
				  :datum index
				  :expected-type `(integer 0 ,(- index save-index))
				  :in-sequence sequence))
			  ((atom list)
			   (error 'must-be-proper-list
				  :name 'elt
				  :datum sequence
				  :expected-type 'list))
			  (t
			   (setf (car list) new-object))))
      (if (>= index (length sequence))
	  (error 'invalid-sequence-index
		 :name 'elt
		 :datum index
		 :expected-type `(integer 0 ,(1- (length sequence)))
		 :in-sequence sequence)
	  (setf (aref sequence index) new-object)))
  new-object)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function count

(defun |count seq-type=general-vector from-end=false key=identity test=eql|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (aref vector i))))

(defun |count seq-type=general-vector from-end=false key=identity test=eq|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (aref vector i))))

(defun |count seq-type=general-vector from-end=false key=identity test=other|
    (item vector start end test)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (aref vector i))))

(defun |count seq-type=general-vector from-end=false key=other test=eql|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=other test=eq|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=other test=other|
    (item vector start end key test)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=identity test=eql|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (aref vector i))))

(defun |count seq-type=general-vector from-end=true key=identity test=eq|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (aref vector i))))

(defun |count seq-type=general-vector from-end=true key=identity test=other|
    (item vector start end test)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (aref vector i))))

(defun |count seq-type=general-vector from-end=true key=other test=eql|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=other test=eq|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=other test=other|
    (item vector start end key test)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (funcall key (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=identity test-not=eql|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=identity test-not=eq|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=identity test-not=other|
    (item vector start end test-not)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (aref vector i)))))

(defun |count seq-type=general-vector from-end=false key=other test-not=eql|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (funcall key (aref vector i))))))

(defun |count seq-type=general-vector from-end=false key=other test-not=eq|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (funcall key (aref vector i))))))

(defun |count seq-type=general-vector from-end=false key=other test-not=other|
    (item vector start end key test-not)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (funcall key (aref vector i))))))

(defun |count seq-type=general-vector from-end=true key=identity test-not=eql|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=identity test-not=eq|
    (item vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=identity test-not=other|
    (item vector start end test-not)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (aref vector i)))))

(defun |count seq-type=general-vector from-end=true key=other test-not=eql|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (funcall key (aref vector i))))))

(defun |count seq-type=general-vector from-end=true key=other test-not=eq|
    (item vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (funcall key (aref vector i))))))

(defun |count seq-type=general-vector from-end=true key=other test-not=other|
    (item vector start end key test-not)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (funcall key (aref vector i))))))

(defun |count seq-type=simple-vector from-end=false key=identity test=eql|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (svref vector i))))

(defun |count seq-type=simple-vector from-end=false key=identity test=eq|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (svref vector i))))

(defun |count seq-type=simple-vector from-end=false key=identity test=other|
    (item vector start end test)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (svref vector i))))

(defun |count seq-type=simple-vector from-end=false key=other test=eql|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=other test=eq|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=other test=other|
    (item vector start end key test)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=identity test=eql|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (svref vector i))))

(defun |count seq-type=simple-vector from-end=true key=identity test=eq|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (svref vector i))))

(defun |count seq-type=simple-vector from-end=true key=identity test=other|
    (item vector start end test)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (svref vector i))))

(defun |count seq-type=simple-vector from-end=true key=other test=eql|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=other test=eq|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=other test=other|
    (item vector start end key test)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (funcall key (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=identity test-not=eql|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=identity test-not=eq|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=identity test-not=other|
    (item vector start end test-not)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=false key=other test-not=eql|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (funcall key (svref vector i))))))

(defun |count seq-type=simple-vector from-end=false key=other test-not=eq|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (funcall key (svref vector i))))))

(defun |count seq-type=simple-vector from-end=false key=other test-not=other|
    (item vector start end key test-not)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (funcall key (svref vector i))))))

(defun |count seq-type=simple-vector from-end=true key=identity test-not=eql|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=identity test-not=eq|
    (item vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=identity test-not=other|
    (item vector start end test-not)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (svref vector i)))))

(defun |count seq-type=simple-vector from-end=true key=other test-not=eql|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (funcall key (svref vector i))))))

(defun |count seq-type=simple-vector from-end=true key=other test-not=eq|
    (item vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (funcall key (svref vector i))))))

(defun |count seq-type=simple-vector from-end=true key=other test-not=other|
    (item vector start end key test-not)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (funcall key (svref vector i))))))

(defun |count seq-type=simple-string from-end=false key=identity test=eql|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (schar vector i))))

(defun |count seq-type=simple-string from-end=false key=identity test=eq|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (schar vector i))))

(defun |count seq-type=simple-string from-end=false key=identity test=other|
    (item vector start end test)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (schar vector i))))

(defun |count seq-type=simple-string from-end=false key=other test=eql|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eql item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=other test=eq|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (eq item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=other test=other|
    (item vector start end key test)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (funcall test item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=identity test=eql|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (schar vector i))))

(defun |count seq-type=simple-string from-end=true key=identity test=eq|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (schar vector i))))

(defun |count seq-type=simple-string from-end=true key=identity test=other|
    (item vector start end test)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (schar vector i))))

(defun |count seq-type=simple-string from-end=true key=other test=eql|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eql item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=other test=eq|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (eq item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=other test=other|
    (item vector start end key test)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall test item (funcall key (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=identity test-not=eql|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=identity test-not=eq|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=identity test-not=other|
    (item vector start end test-not)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (schar vector i)))))

(defun |count seq-type=simple-string from-end=false key=other test-not=eql|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eql item (funcall key (schar vector i))))))

(defun |count seq-type=simple-string from-end=false key=other test-not=eq|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (eq item (funcall key (schar vector i))))))

(defun |count seq-type=simple-string from-end=false key=other test-not=other|
    (item vector start end key test-not)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i from start below end
	count (not (funcall test-not item (funcall key (schar vector i))))))

(defun |count seq-type=simple-string from-end=true key=identity test-not=eql|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=identity test-not=eq|
    (item vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=identity test-not=other|
    (item vector start end test-not)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (schar vector i)))))

(defun |count seq-type=simple-string from-end=true key=other test-not=eql|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eql item (funcall key (schar vector i))))))

(defun |count seq-type=simple-string from-end=true key=other test-not=eq|
    (item vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (eq item (funcall key (schar vector i))))))

(defun |count seq-type=simple-string from-end=true key=other test-not=other|
    (item vector start end key test-not)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall test-not item (funcall key (schar vector i))))))

(defun |count seq-type=list from-end=false end=nil key=identity test=eql|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eql item element)
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=identity test=eq|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eq item element)
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=identity test=other|
    (item list start test)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (funcall test item element)
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test=eql|
    (item list start key)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eql item (funcall key element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test=eq|
    (item list start key)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eq item (funcall key element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test=other|
    (item list start key test)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (funcall test item (funcall key element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=other key=identity test=eql|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eql item element)
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=identity test=eq|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eq item element)
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=identity test=other|
    (item list start end test)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)

	count (funcall test item element)
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test=eql|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eql item (funcall key element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test=eq|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eq item (funcall key element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test=other|
    (item list start end key test)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (funcall test item (funcall key element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=nil key=identity test-not=eql|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eql item element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=identity test-not=eq|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eq item element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=identity test-not=other|
    (item list start test-not)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (funcall test-not item element))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test-not=eql|
    (item list start key)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eql item (funcall key element)))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test-not=eq|
    (item list start key)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eq item (funcall key element)))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=nil key=other test-not=other|
    (item list start key test-not)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (funcall test-not item (funcall key element)))
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=false end=other key=identity test-not=eql|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eql item element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=identity test-not=eq|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eq item element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=identity test-not=other|
    (item list start end test-not)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (funcall test-not item element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test-not=eql|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eql item (funcall key element)))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test-not=eq|
    (item list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eq item (funcall key element)))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=false end=other key=other test-not=other|
    (item list start end key test-not)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (funcall test-not item (funcall key element)))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=true end=nil key=identity test=eql|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eql item element)
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=true end=nil key=identity test=eq|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (eq item element)
	finally (tail-must-be-proper-list 'count list remaining)))

(defun |count seq-type=list from-end=true end=nil key=identity test=other|
    (item list start test)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall test item (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test=eql|
    (item list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (eql item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test=eq|
    (item list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (eq item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test=other|
    (item list start key test)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall test item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=identity test=eql|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eql item element)
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=true end=other key=identity test=eq|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (eq item element)
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=true end=other key=identity test=other|
    (item list start end test)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall test item (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test=eql|
    (item list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (eql item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test=eq|
    (item list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (eq item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test=other|
    (item list start end key test)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall test item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=identity test-not=eql|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eql item element))))

(defun |count seq-type=list from-end=true end=nil key=identity test-not=eq|
    (item list start)
  (loop for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (eq item element))))

(defun |count seq-type=list from-end=true end=nil key=identity test-not=other|
    (item list start test-not)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall test-not item (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test-not=eql|
    (item list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (eql item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test-not=eq|
    (item list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (eq item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=nil key=other test-not=other|
    (item list start key test-not)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall test-not item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=identity test-not=eql|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eql item element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=true end=other key=identity test-not=eq|
    (item list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (eq item element))
	finally (tail-must-be-proper-list-with-end
		     'count list remaining end index)))

(defun |count seq-type=list from-end=true end=other key=identity test-not=other|
    (item list start end test-not)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall test-not item (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test-not=eql|
    (item list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (eql item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test-not=eq|
    (item list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (eq item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count seq-type=list from-end=true end=other key=other test-not=other|
    (item list start end key test-not)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall test-not item (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count from-end=false end=nil key=identity test=eql|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test=eql|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=eql|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=eql|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=eql|
	  item sequence start (length sequence)))))

(defun |count from-end=false end=nil key=identity test=eq|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test=eq|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=eq|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=eq|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=eq|
	  item sequence start (length sequence)))))

(defun |count from-end=false end=nil key=identity test=other|
    (item sequence start test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test=other|
	  item sequence start test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=other|
	  item sequence start (length sequence) test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=other|
	  item sequence start (length sequence) test))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=other|
	  item sequence start (length sequence) test))))

(defun |count from-end=false end=nil key=other test=eql|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test=eql|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=eql|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=eql|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=eql|
	  item sequence start (length sequence) key))))

(defun |count from-end=false end=nil key=other test=eq|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test=eq|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=eq|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=eq|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=eq|
	  item sequence start (length sequence) key))))

(defun |count from-end=false end=nil key=other test=other|
    (item sequence start key test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test=other|
	  item sequence start key test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=other|
	  item sequence start (length sequence) key test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=other|
	  item sequence start (length sequence) key test))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=other|
	  item sequence start (length sequence) key test))))

(defun |count from-end=false end=other key=identity test=eql|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test=eql|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=eql|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=eql|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=eql|
	  item sequence start end))))

(defun |count from-end=false end=other key=identity test=eq|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test=eq|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=eq|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=eq|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=eq|
	  item sequence start end))))

(defun |count from-end=false end=other key=identity test=other|
    (item sequence start end test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test=other|
	  item sequence start end test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test=other|
	  item sequence start end test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test=other|
	  item sequence start end test))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test=other|
	  item sequence start end test))))

(defun |count from-end=false end=other key=other test=eql|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test=eql|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=eql|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=eql|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=eql|
	  item sequence start end key))))

(defun |count from-end=false end=other key=other test=eq|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test=eq|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=eq|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=eq|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=eq|
	  item sequence start end key))))

(defun |count from-end=false end=other key=other test=other|
    (item sequence start end key test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test=other|
	  item sequence start end key test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test=other|
	  item sequence start end key test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test=other|
	  item sequence start end key test))
	(t
	 (|count seq-type=general-vector from-end=false key=other test=other|
	  item sequence start end key test))))

(defun |count from-end=false end=nil key=identity test-not=eql|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test-not=eql|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=eql|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=eql|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=eql|
	  item sequence start (length sequence)))))

(defun |count from-end=false end=nil key=identity test-not=eq|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test-not=eq|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=eq|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=eq|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=eq|
	  item sequence start (length sequence)))))

(defun |count from-end=false end=nil key=identity test-not=other|
    (item sequence start test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=identity test-not=other|
	  item sequence start test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=other|
	  item sequence start (length sequence) test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=other|
	  item sequence start (length sequence) test-not))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=other|
	  item sequence start (length sequence) test-not))))

(defun |count from-end=false end=nil key=other test-not=eql|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test-not=eql|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=eql|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=eql|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=eql|
	  item sequence start (length sequence) key))))

(defun |count from-end=false end=nil key=other test-not=eq|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test-not=eq|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=eq|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=eq|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=eq|
	  item sequence start (length sequence) key))))

(defun |count from-end=false end=nil key=other test-not=other|
    (item sequence start key test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=nil key=other test-not=other|
	  item sequence start key test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=other|
	  item sequence start (length sequence) key test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=other|
	  item sequence start (length sequence) key test-not))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=other|
	  item sequence start (length sequence) key test-not))))

(defun |count from-end=false end=other key=identity test-not=eql|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test-not=eql|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=eql|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=eql|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=eql|
	  item sequence start end))))

(defun |count from-end=false end=other key=identity test-not=eq|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test-not=eq|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=eq|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=eq|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=eq|
	  item sequence start end))))

(defun |count from-end=false end=other key=identity test-not=other|
    (item sequence start end test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=identity test-not=other|
	  item sequence start end test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=identity test-not=other|
	  item sequence start end test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=identity test-not=other|
	  item sequence start end test-not))
	(t
	 (|count seq-type=general-vector from-end=false key=identity test-not=other|
	  item sequence start end test-not))))

(defun |count from-end=false end=other key=other test-not=eql|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test-not=eql|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=eql|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=eql|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=eql|
	  item sequence start end key))))

(defun |count from-end=false end=other key=other test-not=eq|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test-not=eq|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=eq|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=eq|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=eq|
	  item sequence start end key))))

(defun |count from-end=false end=other key=other test-not=other|
    (item sequence start end key test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=false end=other key=other test-not=other|
	  item sequence start end key test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=false key=other test-not=other|
	  item sequence start end key test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=false key=other test-not=other|
	  item sequence start end key test-not))
	(t
	 (|count seq-type=general-vector from-end=false key=other test-not=other|
	  item sequence start end key test-not))))

(defun |count from-end=true end=nil key=identity test=eql|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test=eql|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=eql|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=eql|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=eql|
	  item sequence start (length sequence)))))

(defun |count from-end=true end=nil key=identity test=eq|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test=eq|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=eq|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=eq|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=eq|
	  item sequence start (length sequence)))))

(defun |count from-end=true end=nil key=identity test=other|
    (item sequence start test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test=other|
	  item sequence start test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=other|
	  item sequence start (length sequence) test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=other|
	  item sequence start (length sequence) test))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=other|
	  item sequence start (length sequence) test))))

(defun |count from-end=true end=nil key=other test=eql|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test=eql|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=eql|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=eql|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=eql|
	  item sequence start (length sequence) key))))

(defun |count from-end=true end=nil key=other test=eq|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test=eq|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=eq|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=eq|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=eq|
	  item sequence start (length sequence) key))))

(defun |count from-end=true end=nil key=other test=other|
    (item sequence start key test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test=other|
	  item sequence start key test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=other|
	  item sequence start (length sequence) key test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=other|
	  item sequence start (length sequence) key test))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=other|
	  item sequence start (length sequence) key test))))

(defun |count from-end=true end=other key=identity test=eql|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test=eql|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=eql|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=eql|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=eql|
	  item sequence start end))))

(defun |count from-end=true end=other key=identity test=eq|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test=eq|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=eq|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=eq|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=eq|
	  item sequence start end))))

(defun |count from-end=true end=other key=identity test=other|
    (item sequence start end test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test=other|
	  item sequence start end test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test=other|
	  item sequence start end test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test=other|
	  item sequence start end test))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test=other|
	  item sequence start end test))))

(defun |count from-end=true end=other key=other test=eql|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test=eql|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=eql|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=eql|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=eql|
	  item sequence start end key))))

(defun |count from-end=true end=other key=other test=eq|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test=eq|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=eq|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=eq|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=eq|
	  item sequence start end key))))

(defun |count from-end=true end=other key=other test=other|
    (item sequence start end key test)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test=other|
	  item sequence start end key test))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test=other|
	  item sequence start end key test))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test=other|
	  item sequence start end key test))
	(t
	 (|count seq-type=general-vector from-end=true key=other test=other|
	  item sequence start end key test))))

(defun |count from-end=true end=nil key=identity test-not=eql|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test-not=eql|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=eql|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=eql|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=eql|
	  item sequence start (length sequence)))))

(defun |count from-end=true end=nil key=identity test-not=eq|
    (item sequence start)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test-not=eq|
	  item sequence start))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=eq|
	  item sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=eq|
	  item sequence start (length sequence)))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=eq|
	  item sequence start (length sequence)))))

(defun |count from-end=true end=nil key=identity test-not=other|
    (item sequence start test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=identity test-not=other|
	  item sequence start test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=other|
	  item sequence start (length sequence) test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=other|
	  item sequence start (length sequence) test-not))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=other|
	  item sequence start (length sequence) test-not))))

(defun |count from-end=true end=nil key=other test-not=eql|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test-not=eql|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=eql|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=eql|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=eql|
	  item sequence start (length sequence) key))))

(defun |count from-end=true end=nil key=other test-not=eq|
    (item sequence start key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test-not=eq|
	  item sequence start key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=eq|
	  item sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=eq|
	  item sequence start (length sequence) key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=eq|
	  item sequence start (length sequence) key))))

(defun |count from-end=true end=nil key=other test-not=other|
    (item sequence start key test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=nil key=other test-not=other|
	  item sequence start key test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=other|
	  item sequence start (length sequence) key test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=other|
	  item sequence start (length sequence) key test-not))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=other|
	  item sequence start (length sequence) key test-not))))

(defun |count from-end=true end=other key=identity test-not=eql|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test-not=eql|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=eql|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=eql|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=eql|
	  item sequence start end))))

(defun |count from-end=true end=other key=identity test-not=eq|
    (item sequence start end)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test-not=eq|
	  item sequence start end))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=eq|
	  item sequence start end))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=eq|
	  item sequence start end))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=eq|
	  item sequence start end))))

(defun |count from-end=true end=other key=identity test-not=other|
    (item sequence start end test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=identity test-not=other|
	  item sequence start end test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=identity test-not=other|
	  item sequence start end test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=identity test-not=other|
	  item sequence start end test-not))
	(t
	 (|count seq-type=general-vector from-end=true key=identity test-not=other|
	  item sequence start end test-not))))

(defun |count from-end=true end=other key=other test-not=eql|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test-not=eql|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=eql|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=eql|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=eql|
	  item sequence start end key))))

(defun |count from-end=true end=other key=other test-not=eq|
    (item sequence start end key)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test-not=eq|
	  item sequence start end key))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=eq|
	  item sequence start end key))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=eq|
	  item sequence start end key))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=eq|
	  item sequence start end key))))

(defun |count from-end=true end=other key=other test-not=other|
    (item sequence start end key test-not)
  (cond ((listp sequence)
	 (|count seq-type=list from-end=true end=other key=other test-not=other|
	  item sequence start end key test-not))
	((simple-string-p sequence)
	 (|count seq-type=simple-string from-end=true key=other test-not=other|
	  item sequence start end key test-not))
	((simple-vector-p sequence)
	 (|count seq-type=simple-vector from-end=true key=other test-not=other|
	  item sequence start end key test-not))
	(t
	 (|count seq-type=general-vector from-end=true key=other test-not=other|
	  item sequence start end key test-not))))

(defun count (item sequence
	      &key
	      from-end
	      (start 0)
	      end
	      key
	      (test nil test-p)
	      (test-not nil test-not-p))
  (if from-end
      (if end
	  (if key
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=true end=other key=other test=eql|
		       item sequence start end key)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=true end=other key=other test=eq|
			   item sequence start end key)
			  (|count from-end=true end=other key=other test=other|
			   item sequence start end key test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=true end=other key=other test-not=eql|
			   item sequence start end key)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=true end=other key=other test-not=eq|
			       item sequence start end key)
			      (|count from-end=true end=other key=other test-not=other|
			       item sequence start end key test-not)))
		      (|count from-end=true end=other key=other test=eql|
		       item sequence start end key)))
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=true end=other key=identity test=eql|
		       item sequence start end)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=true end=other key=identity test=eq|
			   item sequence start end)
			  (|count from-end=true end=other key=identity test=other|
			   item sequence start end test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=true end=other key=identity test-not=eql|
			   item sequence start end)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=true end=other key=identity test-not=eq|
			       item sequence start end)
			      (|count from-end=true end=other key=identity test-not=other|
			       item sequence start end test-not)))
		      (|count from-end=true end=other key=identity test=eql|
		       item sequence start end))))
	  (if key
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=true end=nil key=other test=eql|
		       item sequence start key)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=true end=nil key=other test=eq|
			   item sequence start key)
			  (|count from-end=true end=nil key=other test=other|
			   item sequence start key test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=true end=nil key=other test-not=eql|
			   item sequence start key)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=true end=nil key=other test-not=eq|
			       item sequence start key)
			      (|count from-end=true end=nil key=other test-not=other|
			       item sequence start key test-not)))
		      (|count from-end=true end=nil key=other test=eql|
		       item sequence start key)))
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=true end=nil key=identity test=eql|
		       item sequence start)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=true end=nil key=identity test=eq|
			   item sequence start)
			  (|count from-end=true end=nil key=identity test=other|
			   item sequence start test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=true end=nil key=identity test-not=eql|
			   item sequence start)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=true end=nil key=identity test-not=eq|
			       item sequence start)
			      (|count from-end=true end=nil key=identity test-not=other|
			       item sequence start test-not)))
		      (|count from-end=true end=nil key=identity test=eql|
		       item sequence start)))))
      (if end
	  (if key
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=false end=other key=other test=eql|
		       item sequence start end key)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=false end=other key=other test=eq|
			   item sequence start end key)
			  (|count from-end=false end=other key=other test=other|
			   item sequence start end key test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=false end=other key=other test-not=eql|
			   item sequence start end key)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=false end=other key=other test-not=eq|
			       item sequence start end key)
			      (|count from-end=false end=other key=other test-not=other|
			       item sequence start end key test-not)))
		      (|count from-end=false end=other key=other test=eql|
		       item sequence start end key)))
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=false end=other key=identity test=eql|
		       item sequence start end)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=false end=other key=identity test=eq|
			   item sequence start end)
			  (|count from-end=false end=other key=identity test=other|
			   item sequence start end test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=false end=other key=identity test-not=eql|
			   item sequence start end)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=false end=other key=identity test-not=eq|
			       item sequence start end)
			      (|count from-end=false end=other key=identity test-not=other|
			       item sequence start end test-not)))
		      (|count from-end=false end=other key=identity test=eql|
		       item sequence start end))))
	  (if key
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=false end=nil key=other test=eql|
		       item sequence start key)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=false end=nil key=other test=eq|
			   item sequence start key)
			  (|count from-end=false end=nil key=other test=other|
			   item sequence start key test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=false end=nil key=other test-not=eql|
			   item sequence start key)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=false end=nil key=other test-not=eq|
			       item sequence start key)
			      (|count from-end=false end=nil key=other test-not=other|
			       item sequence start key test-not)))
		      (|count from-end=false end=nil key=other test=eql|
		       item sequence start key)))
	      (if test-p
		  (if (or (eq test #'eql) (eq test 'eql))
		      (|count from-end=false end=nil key=identity test=eql|
		       item sequence start)
		      (if (or (eq test #'eq) (eq test 'eq))
			  (|count from-end=false end=nil key=identity test=eq|
			   item sequence start)
			  (|count from-end=false end=nil key=identity test=other|
			   item sequence start test)))
		  (if test-not-p
		      (if (or (eq test-not #'eql) (eq test-not 'eql))
			  (|count from-end=false end=nil key=identity test-not=eql|
			   item sequence start)
			  (if (or (eq test-not #'eq) (eq test-not 'eq))
			      (|count from-end=false end=nil key=identity test-not=eq|
			       item sequence start)
			      (|count from-end=false end=nil key=identity test-not=other|
			       item sequence start test-not)))
		      (|count from-end=false end=nil key=identity test=eql|
		       item sequence start)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function count-if

(defun |count-if seq-type=general-vector from-end=false key=identity|
    (predicate vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (aref vector i))))

(defun |count-if seq-type=general-vector from-end=false key=other|
    (predicate vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (funcall key (aref vector i)))))

(defun |count-if seq-type=general-vector from-end=true key=identity|
    (predicate vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (aref vector i))))

(defun |count-if seq-type=general-vector from-end=true key=other|
    (predicate vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (funcall key (aref vector i)))))

(defun |count-if seq-type=simple-vector from-end=false key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (svref vector i))))

(defun |count-if seq-type=simple-vector from-end=false key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (funcall key (svref vector i)))))

(defun |count-if seq-type=simple-vector from-end=true key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (svref vector i))))

(defun |count-if seq-type=simple-vector from-end=true key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (funcall key (svref vector i)))))

(defun |count-if seq-type=simple-string from-end=false key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (schar vector i))))

(defun |count-if seq-type=simple-string from-end=false key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i from start below end
	count (funcall predicate (funcall key (schar vector i)))))

(defun |count-if seq-type=simple-string from-end=true key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (schar vector i))))

(defun |count-if seq-type=simple-string from-end=true key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if vector start end)
  (loop for i downfrom (1- end) to start
	count (funcall predicate (funcall key (schar vector i)))))

(defun |count-if seq-type=list from-end=false end=nil key=identity|
    (predicate list start)
  (loop for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (funcall predicate element)
	finally (tail-must-be-proper-list 'count-if list remaining)))

(defun |count-if seq-type=list from-end=false end=nil key=other|
    (predicate list start key)
  (loop for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (funcall predicate (funcall key element))
	finally (tail-must-be-proper-list 'count-if list remaining)))

(defun |count-if seq-type=list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (funcall predicate element)
	finally (tail-must-be-proper-list-with-end 'count-if list remaining end index)))

(defun |count-if seq-type=list from-end=false end=other key=other|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (funcall predicate (funcall key element))
	finally (tail-must-be-proper-list-with-end 'count-if list remaining end index)))

(defun |count-if seq-type=list from-end=true end=nil key=identity|
    (predicate list start)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall predicate (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if seq-type=list from-end=true end=nil key=other|
    (predicate list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall predicate (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if seq-type=list from-end=true end=other key=identity|
    (predicate list start end)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall predicate (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if seq-type=list from-end=true end=other key=other|
    (predicate list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (when (funcall predicate (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if from-end=false end=nil key=identity|
    (predicate sequence start)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=false end=nil key=identity|
	  predicate sequence start))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=false key=identity|
	  predicate sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=false key=identity|
	  predicate sequence start (length sequence)))
	(t
	 (|count-if seq-type=general-vector from-end=false key=identity|
	  predicate sequence start (length sequence)))))

(defun |count-if from-end=false end=nil key=other|
    (predicate sequence start key)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=false end=nil key=other|
	  predicate sequence start key))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=false key=other|
	  predicate sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=false key=other|
	  predicate sequence start (length sequence) key))
	(t
	 (|count-if seq-type=general-vector from-end=false key=other|
	  predicate sequence start (length sequence) key))))

(defun |count-if from-end=false end=other key=identity|
    (predicate sequence start end)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=false end=other key=identity|
	  predicate sequence start end))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=false key=identity|
	  predicate sequence start end))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=false key=identity|
	  predicate sequence start end))
	(t
	 (|count-if seq-type=general-vector from-end=false key=identity|
	  predicate sequence start end))))

(defun |count-if from-end=false end=other key=other|
    (predicate sequence start end key)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=false end=other key=other|
	  predicate sequence start end key))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=false key=other|
	  predicate sequence start end key))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=false key=other|
	  predicate sequence start end key))
	(t
	 (|count-if seq-type=general-vector from-end=false key=other|
	  predicate sequence start end key))))

(defun |count-if from-end=true end=nil key=identity|
    (predicate sequence start)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=true end=nil key=identity|
	  predicate sequence start))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=true key=identity|
	  predicate sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=true key=identity|
	  predicate sequence start (length sequence)))
	(t
	 (|count-if seq-type=general-vector from-end=true key=identity|
	  predicate sequence start (length sequence)))))

(defun |count-if from-end=true end=nil key=other|
    (predicate sequence start key)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=true end=nil key=other|
	  predicate sequence start key))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=true key=other|
	  predicate sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=true key=other|
	  predicate sequence start (length sequence) key))
	(t
	 (|count-if seq-type=general-vector from-end=true key=other|
	  predicate sequence start (length sequence) key))))

(defun |count-if from-end=true end=other key=identity|
    (predicate sequence start end)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=true end=other key=identity|
	  predicate sequence start end))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=true key=identity|
	  predicate sequence start end))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=true key=identity|
	  predicate sequence start end))
	(t
	 (|count-if seq-type=general-vector from-end=true key=identity|
	  predicate sequence start end))))

(defun |count-if from-end=true end=other key=other|
    (predicate sequence start end key)
  (cond ((listp sequence)
	 (|count-if seq-type=list from-end=true end=other key=other|
	  predicate sequence start end key))
	((simple-string-p sequence)
	 (|count-if seq-type=simple-string from-end=true key=other|
	  predicate sequence start end key))
	((simple-vector-p sequence)
	 (|count-if seq-type=simple-vector from-end=true key=other|
	  predicate sequence start end key))
	(t
	 (|count-if seq-type=general-vector from-end=true key=other|
	  predicate sequence start end key))))

(defun count-if (predicate sequence &key from-end (start 0) end key)
  (if from-end
      (if end
	  (if key
	      (|count-if from-end=true end=other key=other|
	       predicate sequence start end key)
	      (|count-if from-end=true end=other key=identity|
	       predicate sequence start end))
	  (if key
	      (|count-if from-end=true end=nil key=other|
	       predicate sequence start key)
	      (|count-if from-end=true end=nil key=identity|
	       predicate sequence start)))
      (if end
	  (if key
	      (|count-if from-end=false end=other key=other|
	       predicate sequence start end key)
	      (|count-if from-end=false end=other key=identity|
	       predicate sequence start end))
	  (if key
	      (|count-if from-end=false end=nil key=other|
	       predicate sequence start key)
	      (|count-if from-end=false end=nil key=identity|
	       predicate sequence start)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function count-if-not

(defun |count-if-not seq-type=general-vector from-end=false key=identity|
    (predicate vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (aref vector i)))))

(defun |count-if-not seq-type=general-vector from-end=false key=other|
    (predicate vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (funcall key (aref vector i))))))

(defun |count-if-not seq-type=general-vector from-end=true key=identity|
    (predicate vector start end)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (aref vector i)))))

(defun |count-if-not seq-type=general-vector from-end=true key=other|
    (predicate vector start end key)
  (declare (type vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (funcall key (aref vector i))))))

(defun |count-if-not seq-type=simple-vector from-end=false key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (svref vector i)))))

(defun |count-if-not seq-type=simple-vector from-end=false key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (funcall key (svref vector i))))))

(defun |count-if-not seq-type=simple-vector from-end=true key=identity|
    (predicate vector start end)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (svref vector i)))))

(defun |count-if-not seq-type=simple-vector from-end=true key=other|
    (predicate vector start end key)
  (declare (type simple-vector vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (funcall key (svref vector i))))))

(defun |count-if-not seq-type=simple-string from-end=false key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (schar vector i)))))

(defun |count-if-not seq-type=simple-string from-end=false key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i from start below end
	count (not (funcall predicate (funcall key (schar vector i))))))

(defun |count-if-not seq-type=simple-string from-end=true key=identity|
    (predicate vector start end)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (schar vector i)))))

(defun |count-if-not seq-type=simple-string from-end=true key=other|
    (predicate vector start end key)
  (declare (type simple-string vector)
	   (type fixnum start end))
  (verify-bounding-indexes 'count-if-not vector start end)
  (loop for i downfrom (1- end) to start
	count (not (funcall predicate (funcall key (schar vector i))))))

(defun |count-if-not seq-type=list from-end=false end=nil key=identity|
    (predicate list start)
  (loop for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (funcall predicate element))
	finally (tail-must-be-proper-list 'count-if list remaining)))

(defun |count-if-not seq-type=list from-end=false end=nil key=other|
    (predicate list start key)
  (loop for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (atom remaining)
	for element = (car remaining)
	count (not (funcall predicate (funcall key element)))
	finally (tail-must-be-proper-list 'count-if list remaining)))

(defun |count-if-not seq-type=list from-end=false end=other key=identity|
    (predicate list start end)
  (loop for index from start
	for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (funcall predicate element))
	finally (tail-must-be-proper-list-with-end 'count-if list remaining end index)))

(defun |count-if-not seq-type=list from-end=false end=other key=other|
    (predicate list start end key)
  (loop for index from start
	for remaining = (skip-to-start 'count-if list start) then (cdr remaining)
	until (or (atom remaining) (>= index end))
	for element = (car remaining)
	count (not (funcall predicate (funcall key element)))
	finally (tail-must-be-proper-list-with-end 'count-if list remaining end index)))

(defun |count-if-not seq-type=list from-end=true end=nil key=identity|
    (predicate list start)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall predicate (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if-not seq-type=list from-end=true end=nil key=other|
    (predicate list start key)
  (let* ((remaining (skip-to-start 'count list start))
	 (end (compute-length-from-remainder 'count list remaining start))
	 (result 0))
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall predicate (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if-not seq-type=list from-end=true end=other key=identity|
    (predicate list start end)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall predicate (car list))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if-not seq-type=list from-end=true end=other key=other|
    (predicate list start end key)
  (let* ((remaining (skip-to-start 'count list start))
	 (result 0))
    (verify-end-index 'count list remaining start end)
    (labels ((traverse-list-step-1 (list length)
	       (if (<= length 0)
		   nil
		   (progn (traverse-list-step-1 (cdr list) (1- length))
			  (unless (funcall predicate (funcall key (car list)))
			    (incf result))))))
      (traverse-list #'traverse-list-step-1 remaining (- end start) 1))
    result))

(defun |count-if-not from-end=false end=nil key=identity|
    (predicate sequence start)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=false end=nil key=identity|
	  predicate sequence start))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=false key=identity|
	  predicate sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=false key=identity|
	  predicate sequence start (length sequence)))
	(t
	 (|count-if-not seq-type=general-vector from-end=false key=identity|
	  predicate sequence start (length sequence)))))

(defun |count-if-not from-end=false end=nil key=other|
    (predicate sequence start key)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=false end=nil key=other|
	  predicate sequence start key))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=false key=other|
	  predicate sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=false key=other|
	  predicate sequence start (length sequence) key))
	(t
	 (|count-if-not seq-type=general-vector from-end=false key=other|
	  predicate sequence start (length sequence) key))))

(defun |count-if-not from-end=false end=other key=identity|
    (predicate sequence start end)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=false end=other key=identity|
	  predicate sequence start end))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=false key=identity|
	  predicate sequence start end))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=false key=identity|
	  predicate sequence start end))
	(t
	 (|count-if-not seq-type=general-vector from-end=false key=identity|
	  predicate sequence start end))))

(defun |count-if-not from-end=false end=other key=other|
    (predicate sequence start end key)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=false end=other key=other|
	  predicate sequence start end key))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=false key=other|
	  predicate sequence start end key))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=false key=other|
	  predicate sequence start end key))
	(t
	 (|count-if-not seq-type=general-vector from-end=false key=other|
	  predicate sequence start end key))))

(defun |count-if-not from-end=true end=nil key=identity|
    (predicate sequence start)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=true end=nil key=identity|
	  predicate sequence start))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=true key=identity|
	  predicate sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=true key=identity|
	  predicate sequence start (length sequence)))
	(t
	 (|count-if-not seq-type=general-vector from-end=true key=identity|
	  predicate sequence start (length sequence)))))

(defun |count-if-not from-end=true end=nil key=other|
    (predicate sequence start key)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=true end=nil key=other|
	  predicate sequence start key))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=true key=other|
	  predicate sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=true key=other|
	  predicate sequence start (length sequence) key))
	(t
	 (|count-if-not seq-type=general-vector from-end=true key=other|
	  predicate sequence start (length sequence) key))))

(defun |count-if-not from-end=true end=other key=identity|
    (predicate sequence start end)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=true end=other key=identity|
	  predicate sequence start end))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=true key=identity|
	  predicate sequence start end))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=true key=identity|
	  predicate sequence start end))
	(t
	 (|count-if-not seq-type=general-vector from-end=true key=identity|
	  predicate sequence start end))))

(defun |count-if-not from-end=true end=other key=other|
    (predicate sequence start end key)
  (cond ((listp sequence)
	 (|count-if-not seq-type=list from-end=true end=other key=other|
	  predicate sequence start end key))
	((simple-string-p sequence)
	 (|count-if-not seq-type=simple-string from-end=true key=other|
	  predicate sequence start end key))
	((simple-vector-p sequence)
	 (|count-if-not seq-type=simple-vector from-end=true key=other|
	  predicate sequence start end key))
	(t
	 (|count-if-not seq-type=general-vector from-end=true key=other|
	  predicate sequence start end key))))

(defun count-if-not (predicate sequence &key from-end (start 0) end key)
  (if from-end
      (if end
	  (if key
	      (|count-if-not from-end=true end=other key=other|
	       predicate sequence start end key)
	      (|count-if-not from-end=true end=other key=identity|
	       predicate sequence start end))
	  (if key
	      (|count-if-not from-end=true end=nil key=other|
	       predicate sequence start key)
	      (|count-if-not from-end=true end=nil key=identity|
	       predicate sequence start)))
      (if end
	  (if key
	      (|count-if-not from-end=false end=other key=other|
	       predicate sequence start end key)
	      (|count-if-not from-end=false end=other key=identity|
	       predicate sequence start end))
	  (if key
	      (|count-if-not from-end=false end=nil key=other|
	       predicate sequence start key)
	      (|count-if-not from-end=false end=nil key=identity|
	       predicate sequence start)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function merge

(defun |merge seq-type-1=list seq-type-2=list result-type=list key=identity|
    (l1 l2 predicate)
  (cond ((null l1) l2)
	((null l2) l1)
	(t (let (head)
	     (if (funcall predicate (car l2) (car l1))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (let ((temp (cdr l2)))
		   (setf head l2
			 l2 temp))
		 ;; Take the element of the first sequence if
		 ;; it is less than or equal to the element
		 ;; of the first sequence according to the predicate
		 (let ((temp (cdr l1)))
		   (setf head l1
			 l1 temp)))
	     (let ((tail head))
	       (loop until (or (null l1) (null l2))
		     do (if (funcall predicate (car l2) (car l1))
			    ;; Only if the element of the second sequence
			    ;; is strictly less than the element of the fist
			    ;; sequence according to the predicate should we
			    ;; take the element of the second sequence. 
			    (let ((temp (cdr l2)))
			      (setf (cdr tail) l2
				    l2 temp))
			    ;; Take the element of the first sequence if
			    ;; it is less than or equal to the element
			    ;; of the first sequence according to the predicate
			    (let ((temp (cdr l1)))
			      (setf (cdr tail) l1
				    l1 temp)))
			(setf tail (cdr tail)))
	       (setf (cdr tail)
		     (if (null l1) l2 l1)))
	     head))))

(defun |merge seq-type-1=list seq-type-2=list result-type=list key=other|
    (l1 l2 predicate key)
  (cond ((null l1) l2)
	((null l2) l1)
	(t (let (head)
	     (if (funcall predicate (funcall key (car l2)) (funcall key (car l1)))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (let ((temp (cdr l2)))
		   (setf head l2
			 l2 temp))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (let ((temp (cdr l1)))
		   (setf head l1
			 l1 temp)))
	     (let ((tail head))
	       (loop until (or (null l1) (null l2))
		     do (if (funcall predicate (funcall key (car l2)) (funcall key (car l1)))
			    ;; Only if the element of the second sequence
			    ;; is strictly less than the element of the fist
			    ;; sequence according to the predicate should we
			    ;; take the element of the second sequence. 
			    (let ((temp (cdr l2)))
			      (setf (cdr tail) l2
				    l2 temp))
			    ;; Take the element of the first sequence if it
			    ;; is less than or equal to the element of the
			    ;; first sequence according to the predicate. 
			    (let ((temp (cdr l1)))
			      (setf (cdr tail) l1
				    l1 temp)))
			(setf tail (cdr tail)))
	       (setf (cdr tail)
		     (if (null l1) l2 l1)))
	     head))))

(defun |merge seq-type-1=list seq-type-2=vector result-type=list key=identity|
    (list vector predicate)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length = (length vector)
          for i from 0
	  until (or (= i length) (null list))
	  do (if (funcall predicate (aref vector i) (car list))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (setf (cdr tail) (list (aref vector i))
		       i (1+ i)
		       tail (cdr tail))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (let ((temp (cdr list)))
		   (setf (cdr tail) list
			 tail list
			 list temp)))
	  finally (if (< i length)
		      ;; There are elements left in the second sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length)
			    do (setf (cdr tail) (list (aref vector i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There might be elements left in the fist
		      ;; sequence.  Share structure with it. 
		      (setf (cdr tail) list))
	          (return (cdr sentinel)))))

(defun |merge seq-type-1=list seq-type-2=vector result-type=list key=other|
    (list vector predicate key)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length = (length vector)
          for i from 0
	  until (or (= i length) (null list))
	  do (if (funcall predicate
			  (funcall key (aref vector i))
			  (funcall key (car list)))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (setf (cdr tail) (list (aref vector i))
		       i (1+ i)
		       tail (cdr tail))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (let ((temp (cdr list)))
		   (setf (cdr tail) list
			 tail list
			 list temp)))
	  finally (if (< i length)
		      ;; There are elements left in the second sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length)
			    do (setf (cdr tail) (list (aref vector i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There might be elements left in the fist
		      ;; sequence.  Share structure with it. 
		      (setf (cdr tail) list))
	          (return (cdr sentinel)))))

(defun |merge seq-type-1=vector seq-type-2=list result-type=list key=identity|
    (vector list predicate)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length = (length vector)
          for i from 0
	  until (or (= i length) (null list))
	  do (if (funcall predicate (car list) (aref vector i))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (let ((temp (cdr list)))
		   (setf (cdr tail) list
			 tail list
			 list temp))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (setf (cdr tail) (list (aref vector i))
		       i (1+ i)
		       tail (cdr tail)))
	  finally (if (< i length)
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length)
			    do (setf (cdr tail) (list (aref vector i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There might be elements left in the second
		      ;; sequence.  Share structure with it. 
		      (setf (cdr tail) list))
	          (return (cdr sentinel)))))

(defun |merge seq-type-1=vector seq-type-2=list result-type=list key=other|
    (vector list predicate key)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length = (length vector)
          for i from 0
	  until (or (= i length) (null list))
	  do (if (funcall predicate
			  (funcall key (car list))
			  (funcall key (aref vector i)))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (let ((temp (cdr list)))
		   (setf (cdr tail) list
			 tail list
			 list temp))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (setf (cdr tail) (list (aref vector i))
		       i (1+ i)
		       tail (cdr tail)))
	  finally (if (< i length)
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length)
			    do (setf (cdr tail) (list (aref vector i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There might be elements left in the second
		      ;; sequence.  Share structure with it. 
		      (setf (cdr tail) list))
	          (return (cdr sentinel)))))

(defun |merge seq-type-1=vector seq-type-2=vector result-type=list key=identity|
    (v1 v2 predicate)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length1 = (length v1)
	  with length2 = (length v2)
          for i from 0
	  for j from 0
	  until (or (= i length1) (= j length2))
	  do (if (funcall predicate (aref v2 j) (aref v1 i))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (setf (cdr tail) (list (aref v2 j))
		       j (1+ j)
		       tail (cdr tail))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (setf (cdr tail) (list (aref v1 i))
		       i (1+ i)
		       tail (cdr tail)))
	  finally (if (< i length1)
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length1)
			    do (setf (cdr tail) (list (aref v1 i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= j length2)
			    do (setf (cdr tail) (list (aref v2 j))
				     j (1+ j)
				     tail (cdr tail))))
	          (return (cdr sentinel)))))

(defun |merge seq-type-1=vector seq-type-2=vector result-type=list key=other|
    (v1 v2 predicate key)
  (let* ((sentinel (list nil))
	 (tail sentinel))
    (loop with length1 = (length v1)
	  with length2 = (length v2)
          for i from 0
	  for j from 0
	  until (or (= i length1) (= j length2))
	  do (if (funcall predicate
			  (funcall key (aref v2 j))
			  (funcall key (aref v1 i)))
		 ;; Only if the element of the second sequence
		 ;; is strictly less than the element of the fist
		 ;; sequence according to the predicate should we
		 ;; take the element of the second sequence. 
		 (setf (cdr tail) (list (aref v2 j))
		       j (1+ j)
		       tail (cdr tail))
		 ;; Take the element of the first sequence if it
		 ;; is less than or equal to the element of the
		 ;; first sequence according to the predicate. 
		 (setf (cdr tail) (list (aref v1 i))
		       i (1+ i)
		       tail (cdr tail)))
	  finally (if (< i length1)
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= i length1)
			    do (setf (cdr tail) (list (aref v1 i))
				     i (1+ i)
				     tail (cdr tail)))
		      ;; There are elements left in the first sequence
		      ;; that must be appended to the result. 
		      (loop until (= j length2)
			    do (setf (cdr tail) (list (aref v2 j))
				     j (1+ j)
				     tail (cdr tail))))
	          (return (cdr sentinel)))))

;;; For these special versions, we pass the resulting vector
;;; as an argument, because it has already been created.  
;;; Also, we assume that any list argument has been checked
;;; to be a proper list.

(defun |merge seq-type-1=list seq-type-2=list result-type=vector key=identity|
    (result l1 l2 predicate)
  (loop for i from 0
        until (and (null l1) (null l2))
	do (if (or (null l1) (funcall predicate (car l2) (car l1)))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (car l2)
		     l2 (cdr l2))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (car l1)
		     l1 (cdr l1)))))

(defun |merge seq-type-1=list seq-type-2=list result-type=vector key=other|
    (result l1 l2 predicate key)
  (loop for i from 0
        until (and (null l1) (null l2))
	do (if (or (null l1) (funcall predicate
				      (funcall key (car l2))
				      (funcall key (car l1))))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (car l2)
		     l2 (cdr l2))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (car l1)
		     l1 (cdr l1)))))

(defun |merge seq-type-1=list seq-type-2=vector result-type=vector key=identity|
    (result list vector predicate)
  (loop with length = (length vector)
        with j = 0
        for i from 0
        until (and (null list) (= j length))
	do (if (or (null list) (funcall predicate (aref vector j) (car list)))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (aref vector j)
		     j (1+ j))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (car list)
		     list (cdr list)))))

(defun |merge seq-type-1=list seq-type-2=vector result-type=vector key=other|
    (result list vector predicate key)
  (loop with length = (length vector)
        with j = 0
        for i from 0
        until (and (null list) (= j length))
	do (if (or (null list) (funcall predicate
					(funcall key (aref vector j))
					(funcall key (car list))))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (aref vector j)
		     j (1+ j))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (car list)
		     list (cdr list)))))

(defun |merge seq-type-1=vector seq-type-2=list result-type=vector key=identity|
    (result vector list predicate)
  (loop with length = (length vector)
        with j = 0
        for i from 0
        until (and (= j length) (null list))
	do (if (or (= j length) (funcall predicate (car list) (aref vector j)))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (car list)
		     list (cdr list))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (aref vector j)
		     j (1+ j)))))

(defun |merge seq-type-1=vector seq-type-2=list result-type=vector key=other|
    (result vector list predicate key)
  (loop with length = (length vector)
        with j = 0
        for i from 0
        until (and (= j length) (null list))
	do (if (or (= j length) (funcall predicate
					 (funcall key (car list))
					 (funcall key (aref vector j))))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (car list)
		     list (cdr list))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (aref vector j)
		     j (1+ j)))))

(defun |merge seq-type-1=vector seq-type-2=vector result-type=vector key=identity|
    (result v1 v2 predicate)
  (loop with length1 = (length v1)
        with length2 = (length v2)
        with j = 0
        with k = 0
        for i from 0
        until (and (= j length1) (= k length2))
	do (if (or (= j length1) (funcall predicate (aref v2 k) (aref v1 j)))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (aref v2 k)
		     k (1+ k))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (aref v1 j)
		     j (1+ j)))))

(defun |merge seq-type-1=vector seq-type-2=vector result-type=vector key=other|
    (result v1 v2 predicate key)
  (loop with length1 = (length v1)
        with length2 = (length v2)
        with j = 0
        with k = 0
        for i from 0
        until (and (= j length1) (= k length2))
	do (if (or (= j length1) (funcall predicate
					  (funcall key (aref v2 k))
					  (funcall key (aref v1 j))))
	       ;; Only if the first sequence is empty, or
	       ;; if the element of the second sequence
	       ;; is strictly less than the element of the fist
	       ;; sequence according to the predicate should we
	       ;; take the element of the second sequence. 
	       (setf (aref result i) (aref v2 k)
		     k (1+ k))
	       ;; Take the element of the first sequence if
	       ;; the second sequence is empty or if its first
	       ;; element is less than or equal to the element
	       ;; of the first sequence according to the predicate.
	       (setf (aref result i) (aref v1 j)
		     j (1+ j)))))

(defun merge (result-type sequence-1 sequence-2 predicate &key key)
  (if key
      (if (subtypep result-type 'list)
	  (if (listp sequence-1)
	      (if (listp sequence-2)
		  (|merge seq-type-1=list seq-type-2=list result-type=list key=other|
		   sequence-1 sequence-2 predicate key)
		  (|merge seq-type-1=list seq-type-2=vector result-type=list key=other|
		   sequence-1 sequence-2 predicate key))
	      (if (listp sequence-2)
		  (|merge seq-type-1=vector seq-type-2=list result-type=list key=other|
		   sequence-1 sequence-2 predicate key)
		  (|merge seq-type-1=vector seq-type-2=vector result-type=list key=other|
		   sequence-1 sequence-2 predicate key)))
	  (let* ((length (+ (length-of-proper-sequence 'merge sequence-1)
			    (length-of-proper-sequence 'merge sequence-2)))
		 ;; FIXME: check for incompatible lengths
		 (result (make-sequence result-type length)))
	    (if (listp sequence-1)
		(if (listp sequence-2)
		    (|merge seq-type-1=list seq-type-2=list result-type=vector key=other|
		     result sequence-1 sequence-2 predicate key)
		    (|merge seq-type-1=list seq-type-2=vector result-type=vector key=other|
		     result sequence-1 sequence-2 predicate key))
		(if (listp sequence-2)
		    (|merge seq-type-1=vector seq-type-2=list result-type=vector key=other|
		     result sequence-1 sequence-2 predicate key)
		    (|merge seq-type-1=vector seq-type-2=vector result-type=vector key=other|
		     result sequence-1 sequence-2 predicate key)))
	    result))
      (if (subtypep result-type 'list)
	  (if (listp sequence-1)
	      (if (listp sequence-2)
		  (|merge seq-type-1=list seq-type-2=list result-type=list key=identity|
		   sequence-1 sequence-2 predicate)
		  (|merge seq-type-1=list seq-type-2=vector result-type=list key=identity|
		   sequence-1 sequence-2 predicate))
	      (if (listp sequence-2)
		  (|merge seq-type-1=vector seq-type-2=list result-type=list key=identity|
		   sequence-1 sequence-2 predicate)
		  (|merge seq-type-1=vector seq-type-2=vector result-type=list key=identity|
		   sequence-1 sequence-2 predicate)))
	  (let* ((length (+ (length-of-proper-sequence 'merge sequence-1)
			    (length-of-proper-sequence 'merge sequence-2)))
		 ;; FIXME: check for incompatible lengths
		 (result (make-sequence result-type length)))
	    (if (listp sequence-1)
		(if (listp sequence-2)
		    (|merge seq-type-1=list seq-type-2=list result-type=vector key=identity|
		     result sequence-1 sequence-2 predicate)
		    (|merge seq-type-1=list seq-type-2=vector result-type=vector key=identity|
		     result sequence-1 sequence-2 predicate))
		(if (listp sequence-2)
		    (|merge seq-type-1=vector seq-type-2=list result-type=vector key=identity|
		     result sequence-1 sequence-2 predicate)
		    (|merge seq-type-1=vector seq-type-2=vector result-type=vector key=identity|
		     result sequence-1 sequence-2 predicate)))
	    result))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function sort

(defun |sort seq-type=list length=2| (list predicate)
  (let ((temp (cdr list)))
    (when (funcall predicate (car temp) (car list))
      (rotatef (car temp) (car list))))
  list)

(defun |sort seq-type=list length=3| (list predicate)
  (let* ((temp list)
	 (a (pop temp))
	 (b (pop temp))
	 (c (pop temp)))
    (if (funcall predicate a b)
	(cond ((funcall predicate b c)
	       ;; already sorted
	       nil)
	      ((funcall predicate c a)
	       (setf temp list)
	       (setf (car temp) c
		     temp (cdr temp)
		     (car temp) a
		     temp (cdr temp)
		     (car temp) b))
	      (t
	       (setf temp (cdr list))
	       (setf (car temp) c
		     temp (cdr temp)
		     (car temp) b)))
	(cond ((funcall predicate c b)
	       (setf temp list)
	       (setf (car temp) c
		     temp (cddr temp)
		     (car temp) a))
	      ((funcall predicate a c)
	       (setf temp list)
	       (setf (car temp) b
		     temp (cdr temp)
		     (car temp) a))
	      (t
	       (setf temp list)
	       (setf (car temp) b
		     temp (cdr temp)
		     (car temp) c
		     temp (cdr temp)
		     (car temp) a))))
    list))

(defun |sort seq-type=simple-vector length=3|
    (vector predicate start)
  (let* ((a (svref vector start))
	 (b (svref vector (1+ start)))
	 (c (svref vector (+ start 2))))
    (if (funcall predicate a b)
	(cond ((funcall predicate b c)
	       ;; already sorted
	       nil)
	      ((funcall predicate c a)
	       (setf (svref vector start) c
		     (svref vector (1+ start)) a
		     (svref vector (+ start 2)) b))
	      (t
	       (setf (svref vector (1+ start)) c
		     (svref vector (+ start 2)) b)))
	(cond ((funcall predicate c b)
	       (setf (svref vector start) c
		     (svref vector (+ start 2)) a))
	      ((funcall predicate a c)
	       (setf (svref vector start) b
		     (svref vector (1+ start)) a))
	      (t
	       (setf (svref vector start) b
		     (svref vector (1+ start)) c
		     (svref vector (+ start 2)) a))))))

(defun |sort seq-type=list key=identity|
    (list predicate)
  (labels ((sort-with-length (list length)
	     (case length
	       ((0 1) list)
	       (2 (let ((temp (cdr list)))
		    (when (funcall predicate (car temp) (car list))
		      (rotatef (car temp) (car list))))
		  list)
	       (3 (|sort seq-type=list length=3| list predicate))
	       (t (let* ((l1 (floor length 2))
			 (l2 (- length l1))
			 (middle (nthcdr (1- l1) list))
			 (second (cdr middle)))
		    (setf (cdr middle) nil)
		    (|merge seq-type-1=list seq-type-2=list result-type=list key=identity|
		     (sort-with-length list l1)
		     (sort-with-length second l2)
		     predicate))))))
    (sort-with-length list (length list))))

(defun |sort seq-type=simple-vector key=identity|
    (vector predicate)
  (declare (type simple-vector vector))
  (declare (optimize (speed 3) (debug 0) (safety 0)))
  (labels ((sort-interval (start end)
	     (declare (type fixnum start end))
	     (case (- end start)
	       ((0 1) nil)
	       (2 (when (funcall predicate
				 (svref vector (1+ start))
				 (svref vector start))
		    (rotatef (svref vector (1+ start))
			     (svref vector start))))
	       (3 (|sort seq-type=simple-vector length=3|
		   vector predicate start))
	       (t
		  (let* ((middle (floor (+ start end) 2))
			 (pivot (svref vector middle)))
		    ;; Exclude the pivot element in order
		    ;; to make sure each part is strictly
		    ;; smaller than the whole. 
		    (rotatef (svref vector middle)
			     (svref vector (1- end)))
		    (let ((i start)
			  (j (- end 2)))
		      (declare (type fixnum i j))
		      (loop while (<= i j)
			    do (loop while (and (<= i j)
						(not (funcall predicate
							      pivot
							      (svref vector i))))
				     do (incf i))
			       (loop while (and (<= i j)
						(not (funcall predicate
							      (svref vector j)
							      pivot)))
				     do (decf j))
			       (when (< i j)
				 (rotatef (svref vector i) (svref vector j))
				 (incf i)
				 (decf j)))
		      (setf (svref vector (1- end))
			    (svref vector i))
		      (setf (svref vector i) pivot)
		      (sort-interval start i)
		      (sort-interval (1+ i) end)))))
	     nil))
    (sort-interval 0 (length vector)))
  vector)
	     
(defun sort (sequence predicate &key key)
  (if (listp sequence)
      (if key
	  nil
	  (|sort seq-type=list key=identity| sequence predicate))
      (if (simple-vector-p sequence)
	  (if key
	      nil
	      (|sort seq-type=simple-vector key=identity| sequence predicate))
	  nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function nsubstitute

(defun |nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
    (newitem olditem list start)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eql olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test=eql count=nil key=other|
    (newitem olditem list start key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eql olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test=eq count=nil key=identity|
    (newitem olditem list start)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eq olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test=eq count=nil key=other|
    (newitem olditem list start key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eq olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test=other count=nil key=identity|
    (newitem olditem list start test)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall test olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test=other count=nil key=other|
    (newitem olditem list start test key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=other count=other key=identity|
    (newitem olditem list start test count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall test olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test=other count=other key=other|
    (newitem olditem list start test count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=eql count=nil key=identity|
    (newitem olditem list start)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eql olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=eql count=nil key=other|
    (newitem olditem list start key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=eql count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eql olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=eql count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=eq count=nil key=identity|
    (newitem olditem list start)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eq olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=eq count=nil key=other|
    (newitem olditem list start key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=eq count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eq olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=eq count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=other count=nil key=identity|
    (newitem olditem list start test-not)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=nil test-not=other count=nil key=other|
    (newitem olditem list start test-not key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=other count=other key=identity|
    (newitem olditem list start test-not count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list from-end=false end=nil test-not=other count=other key=other|
    (newitem olditem list start test-not count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute seq-type=list end=other test=eql count=nil key=identity|
    (newitem olditem list start end)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eql olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test=eql count=nil key=other|
    (newitem olditem list start end key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=eql count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eql olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=eql count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test=eq count=nil key=identity|
    (newitem olditem list start end)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eq olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test=eq count=nil key=other|
    (newitem olditem list start end key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=eq count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eq olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=eq count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test=other count=nil key=identity|
    (newitem olditem list start end test)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall test olditem (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test=other count=nil key=other|
    (newitem olditem list start end test key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=other count=other key=identity|
    (newitem olditem list start end test count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall test olditem (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test=other count=other key=other|
    (newitem olditem list start end test count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=eql count=nil key=identity|
    (newitem olditem list start end)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eql olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=eql count=nil key=other|
    (newitem olditem list start end key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=eql count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eql olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=eql count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=eq count=nil key=identity|
    (newitem olditem list start end)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eq olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=eq count=nil key=other|
    (newitem olditem list start end key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=eq count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eq olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=eq count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=other count=nil key=identity|
    (newitem olditem list start end test-not)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list end=other test-not=other count=nil key=other|
    (newitem olditem list start end test-not key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=other count=other key=identity|
    (newitem olditem list start end test-not count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=false end=other test-not=other count=other key=other|
    (newitem olditem list start end test-not count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eql olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eql olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=eq count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eq olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=eq count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eq olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=other count=other key=identity|
    (newitem olditem list start test count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall test olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test=other count=other key=other|
    (newitem olditem list start test count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall test olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=eql count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eql olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=eql count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eql olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=eq count=other key=identity|
    (newitem olditem list start count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eq olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=eq count=other key=other|
    (newitem olditem list start count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eq olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=other count=other key=identity|
    (newitem olditem list start test-not count)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall test-not olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=nil test-not=other count=other key=other|
    (newitem olditem list start test-not count key)
  (let ((remaining (skip-to-start 'nsubstitute list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall test-not olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=eql count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eql olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=eql count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eql olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=eq count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eq olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=eq count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (eq olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=other count=other key=identity|
    (newitem olditem list start end test count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall test olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test=other count=other key=other|
    (newitem olditem list start end test count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall test olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=eql count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eql olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=eql count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eql olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=eq count=other key=identity|
    (newitem olditem list start end count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eq olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=eq count=other key=other|
    (newitem olditem list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (eq olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=other count=other key=identity|
    (newitem olditem list start end test-not count)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall test-not olditem (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=list from-end=true end=other test-not=other count=other key=other|
    (newitem olditem list start end test-not count key)
  (let ((remaining (skip-to-start 'nsubstitute list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall test-not olditem (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute seq-type=general-vector test=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test=other count=nil key=identity|
    (newitem olditem vector start end test)
  (loop for i from start below end
	do (when (funcall test olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test=other count=nil key=other|
    (newitem olditem vector start end test key)
  (loop for i from start below end
	do (when (funcall test olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=other count=nil key=identity|
    (newitem olditem vector start end test-not)
  (loop for i from start below end
	do (unless (funcall test-not olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector test-not=other count=nil key=other|
    (newitem olditem vector start end test-not key)
  (loop for i from start below end
	do (unless (funcall test-not olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=other count=other key=identity|
    (newitem olditem vector start end test count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=false test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=other count=other key=identity|
    (newitem olditem vector start end count test)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=general-vector from-end=true test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=other count=nil key=identity|
    (newitem olditem vector start end test)
  (loop for i from start below end
	do (when (funcall test olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test=other count=nil key=other|
    (newitem olditem vector start end test key)
  (loop for i from start below end
	do (when (funcall test olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=other count=nil key=identity|
    (newitem olditem vector start end test-not)
  (loop for i from start below end
	do (unless (funcall test-not olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector test-not=other count=nil key=other|
    (newitem olditem vector start end test-not key)
  (loop for i from start below end
	do (unless (funcall test-not olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=other count=other key=identity|
    (newitem olditem vector start end test count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=false test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=other count=other key=identity|
    (newitem olditem vector start end test count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-vector from-end=true test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (when (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (when (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=other count=nil key=identity|
    (newitem olditem vector start end test)
  (loop for i from start below end
	do (when (funcall test olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test=other count=nil key=other|
    (newitem olditem vector start end test key)
  (loop for i from start below end
	do (when (funcall test olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=eql count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=eql count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=eq count=nil key=identity|
    (newitem olditem vector start end)
  (loop for i from start below end
	do (unless (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=eq count=nil key=other|
    (newitem olditem vector start end key)
  (loop for i from start below end
	do (unless (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=other count=nil key=identity|
    (newitem olditem vector start end test-not)
  (loop for i from start below end
	do (unless (funcall test-not olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string test-not=other count=nil key=other|
    (newitem olditem vector start end test-not key)
  (loop for i from start below end
	do (unless (funcall test-not olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=other count=other key=identity|
    (newitem olditem vector start end test count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=false test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=other count=other key=identity|
    (newitem olditem vector start end test count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test=other count=other key=other|
    (newitem olditem vector start end test count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall test olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=eql count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=eql count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eql olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=eq count=other key=identity|
    (newitem olditem vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=eq count=other key=other|
    (newitem olditem vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (eq olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=other count=other key=identity|
    (newitem olditem vector start end test-not count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute seq-type=simple-string from-end=true test-not=other count=other key=other|
    (newitem olditem vector start end test-not count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall test-not olditem (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute end=nil test=eql count=nil key=identity|
    (newitem olditem sequence start)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
	  newitem olditem sequence start))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	(t
	 (|nsubstitute seq-type=general-vector test=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))))

(defun |nsubstitute end=nil test=eql count=nil key=other|
    (newitem olditem sequence start key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=eql count=nil key=other|
	  newitem olditem sequence start key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	(t
	 (|nsubstitute seq-type=general-vector test=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))))

(defun |nsubstitute end=nil test=eq count=nil key=identity|
    (newitem olditem sequence start)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=eq count=nil key=identity|
	  newitem olditem sequence start))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	(t
	 (|nsubstitute seq-type=general-vector test=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))))

(defun |nsubstitute end=nil test=eq count=nil key=other|
    (newitem olditem sequence start key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=eq count=nil key=other|
	  newitem olditem sequence start key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	(t
	 (|nsubstitute seq-type=general-vector test=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))))

(defun |nsubstitute end=nil test=other count=nil key=identity|
    (newitem olditem sequence start test)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=other count=nil key=identity|
	  newitem olditem sequence start test))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test))
	(t
	 (|nsubstitute seq-type=general-vector test=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test))))

(defun |nsubstitute end=nil test=other count=nil key=other|
    (newitem olditem sequence start test key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test=other count=nil key=other|
	  newitem olditem sequence start test key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test key))
	(t
	 (|nsubstitute seq-type=general-vector test=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test key))))

(defun |nsubstitute end=nil test-not=eql count=nil key=identity|
    (newitem olditem sequence start)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=identity|
	  newitem olditem sequence start))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	(t
	 (|nsubstitute seq-type=general-vector test-not=eql count=nil key=identity|
	  newitem olditem sequence start (length sequence)))))

(defun |nsubstitute end=nil test-not=eql count=nil key=other|
    (newitem olditem sequence start key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=other|
	  newitem olditem sequence start key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	(t
	 (|nsubstitute seq-type=general-vector test-not=eql count=nil key=other|
	  newitem olditem sequence start (length sequence) key))))

(defun |nsubstitute end=nil test-not=eq count=nil key=identity|
    (newitem olditem sequence start)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=identity|
	  newitem olditem sequence start))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))
	(t
	 (|nsubstitute seq-type=general-vector test-not=eq count=nil key=identity|
	  newitem olditem sequence start (length sequence)))))

(defun |nsubstitute end=nil test-not=eq count=nil key=other|
    (newitem olditem sequence start key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=other|
	  newitem olditem sequence start key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))
	(t
	 (|nsubstitute seq-type=general-vector test-not=eq count=nil key=other|
	  newitem olditem sequence start (length sequence) key))))

(defun |nsubstitute end=nil test-not=other count=nil key=identity|
    (newitem olditem sequence start test-not)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=other count=nil key=identity|
	  newitem olditem sequence start test-not))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test-not))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test-not))
	(t
	 (|nsubstitute seq-type=general-vector test-not=other count=nil key=identity|
	  newitem olditem sequence start (length sequence) test-not))))

(defun |nsubstitute end=nil test-not=other count=nil key=other|
    (newitem olditem sequence start test-not key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list end=nil test-not=other count=nil key=other|
	  newitem olditem sequence start test-not key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string test-not=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test-not key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector test-not=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test-not key))
	(t
	 (|nsubstitute seq-type=general-vector test-not=other count=nil key=other|
	  newitem olditem sequence start (length sequence) test-not key))))

(defun |nsubstitute from-end=false end=nil test=eql count=other key=identity|
    (newitem olditem sequence start count)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
	  newitem olditem sequence start count))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=identity|
	  newitem olditem sequence start (length sequence) count))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=identity|
	  newitem olditem sequence start (length sequence) count))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=identity|
	  newitem olditem sequence start (length sequence) count))))

(defun |nsubstitute from-end=false end=nil test=eql count=other key=other|
    (newitem olditem sequence start count key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=other|
	  newitem olditem sequence start count key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=other|
	  newitem olditem sequence start (length sequence) count key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=other|
	  newitem olditem sequence start (length sequence) count key))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=other|
	  newitem olditem sequence start (length sequence) count key))))

(defun |nsubstitute from-end=false end=nil test=eq count=other key=identity|
    (newitem olditem sequence start count)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=identity|
	  newitem olditem sequence start count))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=identity|
	  newitem olditem sequence start (length sequence) count))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=identity|
	  newitem olditem sequence start (length sequence) count))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=identity|
	  newitem olditem sequence start (length sequence) count))))

(defun |nsubstitute from-end=false end=nil test=eq count=other key=other|
    (newitem olditem sequence start count key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=other|
	  newitem olditem sequence start count key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=other|
	  newitem olditem sequence start (length sequence) count key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=other|
	  newitem olditem sequence start (length sequence) count key))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=other|
	  newitem olditem sequence start (length sequence) count key))))

(defun |nsubstitute from-end=false end=nil test=other count=other key=identity|
    (newitem olditem sequence start test count)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=other count=other key=identity|
	  newitem olditem sequence start test count))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=identity|
	  newitem olditem sequence start (length sequence) test count))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=other count=other key=identity|
	  newitem olditem sequence start (length sequence) test count))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=identity|
	  newitem olditem sequence start (length sequence) test count))))

(defun |nsubstitute from-end=false end=nil test=other count=other key=other|
    (newitem olditem sequence start test count key)
  (cond ((listp sequence)
	 (|nsubstitute seq-type=list from-end=false end=nil test=other count=other key=other|
	  newitem olditem sequence start test count key))
	((simple-string-p sequence)
	 (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=other|
	  newitem olditem sequence start (length sequence) test count key))
	((simple-vector-p sequence)
	 (|nsubstitute seq-type=simple-vector from-end=false test=other count=other key=other|
	  newitem olditem sequence start (length sequence) test count key))
	(t
	 (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=other|
	  newitem olditem sequence start (length sequence) test count key))))

(defun nsubstitute
    (newitem olditem sequence &key from-end test test-not (start 0) end count key)
  (assert (or (null test) (null test-not)))
  (cond ((listp sequence)
	 (cond (test
		(cond ((or (eq test #'eql) (eq test 'eql))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=true end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=false end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))))
		      ((or (eq test #'eq) (eq test 'eq))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=true end=other test=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eq count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=false end=other test=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eq count=nil key=identity|
					newitem olditem sequence start))))))
		      (t
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test=other count=other key=other|
					newitem olditem sequence start end test count key)
				       (|nsubstitute seq-type=list from-end=true end=other test=other count=other key=identity|
					newitem olditem sequence start end test count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=other count=nil key=other|
					newitem olditem sequence start end test key)
				       (|nsubstitute seq-type=list end=other test=other count=nil key=identity|
					newitem olditem sequence start end test)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test=other count=other key=other|
					newitem olditem sequence start test count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test=other count=other key=identity|
					newitem olditem sequence start test count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=other count=nil key=other|
					newitem olditem sequence start test key)
				       (|nsubstitute seq-type=list end=nil test=other count=nil key=identity|
					newitem olditem sequence start test))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test=other count=other key=other|
					newitem olditem sequence start end test count key)
				       (|nsubstitute seq-type=list from-end=false end=other test=other count=other key=identity|
					newitem olditem sequence start end test count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=other count=nil key=other|
					newitem olditem sequence start end test key)
				       (|nsubstitute seq-type=list end=other test=other count=nil key=identity|
					newitem olditem sequence start test end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test=other count=other key=other|
					newitem olditem sequence start test count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test=other count=other key=identity|
					newitem olditem sequence start test count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=other count=nil key=other|
					newitem olditem sequence start test key)
				       (|nsubstitute seq-type=list end=nil test=other count=nil key=identity|
					newitem olditem sequence start test))))))))
	       (test-not
		(cond ((or (eq test-not #'eql) (eq test-not 'eql))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test-not=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=true end=other test-not=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test-not=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test-not=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=false end=other test-not=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test-not=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test-not=eql count=nil key=identity|
					newitem olditem sequence start))))))
		      ((or (eq test-not #'eq) (eq test-not 'eq))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test-not=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=true end=other test-not=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test-not=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test-not=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=false end=other test-not=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test-not=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test-not=eq count=nil key=identity|
					newitem olditem sequence start))))))
		      (t
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test-not=other count=other key=other|
					newitem olditem sequence start end test-not count key)
				       (|nsubstitute seq-type=list from-end=true end=other test-not=other count=other key=identity|
					newitem olditem sequence start end test-not count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=other count=nil key=other|
					newitem olditem sequence start end test-not key)
				       (|nsubstitute seq-type=list end=other test-not=other count=nil key=identity|
					newitem olditem sequence start end test-not)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=other count=other key=other|
					newitem olditem sequence start test-not count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test-not=other count=other key=identity|
					newitem olditem sequence start test-not count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=other count=nil key=other|
					newitem olditem sequence start test-not key)
				       (|nsubstitute seq-type=list end=nil test-not=other count=nil key=identity|
					newitem olditem sequence start test-not))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test-not=other count=other key=other|
					newitem olditem sequence start end test-not count key)
				       (|nsubstitute seq-type=list from-end=false end=other test-not=other count=other key=identity|
					newitem olditem sequence start end test-not count))
				   (if key
				       (|nsubstitute seq-type=list end=other test-not=other count=nil key=other|
					newitem olditem sequence start end test-not key)
				       (|nsubstitute seq-type=list end=other test-not=other count=nil key=identity|
					newitem olditem sequence start end test-not)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=other count=other key=other|
					newitem olditem sequence start test-not count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test-not=other count=other key=identity|
					newitem olditem sequence start test-not count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test-not=other count=nil key=other|
					newitem olditem sequence start test-not key)
				       (|nsubstitute seq-type=list end=nil test-not=other count=nil key=identity|
					newitem olditem sequence start test-not))))))))
	       (t
		(if from-end
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=true end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|nsubstitute seq-type=list from-end=false end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|nsubstitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|nsubstitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|nsubstitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))))))
	((simple-string-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (cond (test
		(cond ((or (eq test #'eql) (eq test 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=true test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test #'eq) (eq test 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=true test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=false test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=simple-string from-end=true test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=simple-string test=other count=nil key=identity|
				    newitem olditem sequence start test end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=simple-string from-end=false test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=simple-string test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=simple-string test=other count=nil key=identity|
				    newitem olditem sequence start end test)))))))
	       (test-not
		(cond ((or (eq test-not #'eql) (eq test-not 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=true test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=false test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test-not #'eq) (eq test-not 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=true test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-string from-end=false test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-string test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=true test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=simple-string from-end=true test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=simple-string test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-string from-end=false test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=simple-string from-end=false test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=simple-string test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=simple-string test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))))))
	       (t
		(if from-end
		    (if count
			(if key
			    (|nsubstitute seq-type=simple-string from-end=true test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=simple-string from-end=true test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=simple-string test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=simple-string test=eql count=nil key=identity|
			     newitem olditem sequence start end)))
		    (if count
			(if key
			    (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=simple-string from-end=false test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=simple-string test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=simple-string test=eql count=nil key=identity|
			     newitem olditem sequence start end)))))))
	((simple-vector-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (cond (test
		(cond ((or (eq test #'eql) (eq test 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test #'eq) (eq test 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=simple-vector test=other count=nil key=identity|
				    newitem olditem sequence start end test)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=simple-vector test=other count=nil key=identity|
				    newitem olditem sequence start end test)))))))
	       (test-not
		(cond ((or (eq test-not #'eql) (eq test-not 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test-not #'eq) (eq test-not 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=simple-vector test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=simple-vector from-end=true test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=simple-vector test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=simple-vector from-end=false test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=simple-vector test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=simple-vector test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))))))
	       (t
		(if from-end
		    (if count
			(if key
			    (|nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=simple-vector from-end=true test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=simple-vector test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
			     newitem olditem sequence start end)))
		    (if count
			(if key
			    (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=simple-vector from-end=false test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=simple-vector test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=simple-vector test=eql count=nil key=identity|
			     newitem olditem sequence start end)))))))
	(t
	 (when (null end)
	   (setf end (length sequence)))
	 (cond (test
		(cond ((or (eq test #'eql) (eq test 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=true test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=false test=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test #'eq) (eq test 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=true test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=false test=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=general-vector from-end=true test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=general-vector test=other count=nil key=identity|
				    newitem olditem sequence start end test)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test=other count=other key=other|
				    newitem olditem sequence start end test count key)
				   (|nsubstitute seq-type=general-vector from-end=false test=other count=other key=identity|
				    newitem olditem sequence start end test count))
			       (if key
				   (|nsubstitute seq-type=general-vector test=other count=nil key=other|
				    newitem olditem sequence start end test key)
				   (|nsubstitute seq-type=general-vector test=other count=nil key=identity|
				    newitem olditem sequence start end test)))))))
	       (test-not
		(cond ((or (eq test-not #'eql) (eq test-not 'eql))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=true test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test-not=eql count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=false test-not=eql count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=eql count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test-not=eql count=nil key=identity|
				    newitem olditem sequence start end)))))
		      ((or (eq test-not #'eq) (eq test-not 'eq))
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=true test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test-not=eq count=other key=other|
				    newitem olditem sequence start end count key)
				   (|nsubstitute seq-type=general-vector from-end=false test-not=eq count=other key=identity|
				    newitem olditem sequence start end count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=eq count=nil key=other|
				    newitem olditem sequence start end key)
				   (|nsubstitute seq-type=general-vector test-not=eq count=nil key=identity|
				    newitem olditem sequence start end)))))
		      (t
		       (if from-end
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=true test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=general-vector from-end=true test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=general-vector test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))
			   (if count
			       (if key
				   (|nsubstitute seq-type=general-vector from-end=false test-not=other count=other key=other|
				    newitem olditem sequence start end test-not count key)
				   (|nsubstitute seq-type=general-vector from-end=false test-not=other count=other key=identity|
				    newitem olditem sequence start end test-not count))
			       (if key
				   (|nsubstitute seq-type=general-vector test-not=other count=nil key=other|
				    newitem olditem sequence start end test-not key)
				   (|nsubstitute seq-type=general-vector test-not=other count=nil key=identity|
				    newitem olditem sequence start end test-not)))))))
	       (t
		(if from-end
		    (if count
			(if key
			    (|nsubstitute seq-type=general-vector from-end=true test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=general-vector from-end=true test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=general-vector test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=general-vector test=eql count=nil key=identity|
			     newitem olditem sequence start end)))
		    (if count
			(if key
			    (|nsubstitute seq-type=general-vector from-end=false test=eql count=other key=other|
			     newitem olditem sequence start end count key)
			    (|nsubstitute seq-type=general-vector from-end=false test=eql count=other key=identity|
			     newitem olditem sequence start end count))
			(if key
			    (|nsubstitute seq-type=general-vector test=eql count=nil key=other|
			     newitem olditem sequence start end key)
			    (|nsubstitute seq-type=general-vector test=eql count=nil key=identity|
			     newitem olditem sequence start end)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function nsubstitute-if

(defun |nsubstitute-if seq-type=list end=nil count=nil key=identity|
    (newitem predicate list start)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if seq-type=list end=nil count=nil key=other|
    (newitem predicate list start key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if seq-type=list from-end=false end=nil count=other key=identity|
    (newitem predicate list start count)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if seq-type=list from-end=false end=nil count=other key=other|
    (newitem predicate list start count key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if seq-type=list end=other count=nil key=identity|
    (newitem predicate list start end)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if seq-type=list end=other count=nil key=other|
    (newitem predicate list start end key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if seq-type=list from-end=false end=other count=other key=identity|
    (newitem predicate list start end count)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if seq-type=list from-end=false end=other count=other key=other|
    (newitem predicate list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if seq-type=list from-end=true end=nil count=other key=identity|
    (newitem predicate list start count)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall predicate (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if seq-type=list from-end=true end=nil count=other key=other|
    (newitem predicate list start count key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall predicate (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if seq-type=list from-end=true end=other count=other key=identity|
    (newitem predicate list start end count)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall predicate (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if seq-type=list from-end=true end=other count=other key=other|
    (newitem predicate list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute-if list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (loop until (null reversed)
	    while (plusp count)
	    do (when (funcall predicate (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if seq-type=general-vector count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (when (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=general-vector count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (when (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=general-vector from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=general-vector from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=general-vector from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=general-vector from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (when (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (when (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-vector from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (when (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (when (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if seq-type=simple-string from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (when (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun nsubstitute-if
    (newitem predicate sequence &key from-end (start 0) end count key)
  (cond ((listp sequence)
	 (if from-end
	     (if end
		 (if count
		     (if key
			 (|nsubstitute-if seq-type=list from-end=true end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|nsubstitute-if seq-type=list from-end=true end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|nsubstitute-if seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|nsubstitute-if seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|nsubstitute-if seq-type=list from-end=true end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|nsubstitute-if seq-type=list from-end=true end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|nsubstitute-if seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|nsubstitute-if seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))
	     (if end
		 (if count
		     (if key
			 (|nsubstitute-if seq-type=list from-end=false end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|nsubstitute-if seq-type=list from-end=false end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|nsubstitute-if seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|nsubstitute-if seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|nsubstitute-if seq-type=list from-end=false end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|nsubstitute-if seq-type=list from-end=false end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|nsubstitute-if seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|nsubstitute-if seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))))
	((simple-string-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=simple-string from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=simple-string from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=simple-string count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=simple-string count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=simple-string from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=simple-string from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=simple-string count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=simple-string count=nil key=identity|
		      newitem predicate sequence start end)))))
	((simple-vector-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=simple-vector from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=simple-vector from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=simple-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=simple-vector count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=simple-vector from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=simple-vector from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=simple-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=simple-vector count=nil key=identity|
		      newitem predicate sequence start end)))))
	(t
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=general-vector from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=general-vector from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=general-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=general-vector count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if seq-type=general-vector from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if seq-type=general-vector from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if seq-type=general-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if seq-type=general-vector count=nil key=identity|
		      newitem predicate sequence start end)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function nsubstitute-if-not

(defun |nsubstitute-if-not seq-type=list end=nil count=nil key=identity|
    (newitem predicate list start)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  unless (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if-not seq-type=list end=nil count=nil key=other|
    (newitem predicate list start key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=false end=nil count=other key=identity|
    (newitem predicate list start count)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  unless (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=false end=nil count=other key=other|
    (newitem predicate list start count key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))))
  list)

(defun |nsubstitute-if-not seq-type=list end=other count=nil key=identity|
    (newitem predicate list start end)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  unless (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if-not seq-type=list end=other count=nil key=other|
    (newitem predicate list start end key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=false end=other count=other key=identity|
    (newitem predicate list start end count)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  unless (funcall predicate (car remaining))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=false end=other count=other key=other|
    (newitem predicate list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (car remaining) newitem)
	       (decf count)
	  do (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list)))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=true end=nil count=other key=identity|
    (newitem predicate list start count)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall predicate (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=true end=nil count=other key=other|
    (newitem predicate list start count key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall predicate (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=true end=other count=other key=identity|
    (newitem predicate list start end count)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall predicate (car reversed))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if-not seq-type=list from-end=true end=other count=other key=other|
    (newitem predicate list start end count key)
  (let ((remaining (skip-to-start 'nsubstitute-if-not list start))
	(end-start (- end start)))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (loop until (null reversed)
	    while (plusp count)
	    do (unless (funcall predicate (funcall key (car reversed)))
		 (setf (car reversed) newitem)
		 (decf count))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp)))))
  list)

(defun |nsubstitute-if-not seq-type=general-vector count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (unless (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=general-vector count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (unless (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=general-vector from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=general-vector from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=general-vector from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (aref vector i))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=general-vector from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (aref vector i)))
	     (setf (aref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (unless (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (unless (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (svref vector i))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-vector from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (svref vector i)))
	     (setf (svref vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string count=nil key=identity|
    (newitem predicate vector start end)
  (loop for i from start below end
	do (unless (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string count=nil key=other|
    (newitem predicate vector start end key)
  (loop for i from start below end
	do (unless (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string from-end=false count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string from-end=false count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i from start below end
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string from-end=true count=other key=identity|
    (newitem predicate vector start end count)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (schar vector i))
	     (setf (schar vector i) newitem)))
  vector)

(defun |nsubstitute-if-not seq-type=simple-string from-end=true count=other key=other|
    (newitem predicate vector start end count key)
  (loop for i downfrom (1- end) to start
	while (plusp count)
	do (decf count)
	   (unless (funcall predicate (funcall key (schar vector i)))
	     (setf (schar vector i) newitem)))
  vector)

(defun nsubstitute-if-not
    (newitem predicate sequence &key from-end (start 0) end count key)
  (cond ((listp sequence)
	 (if from-end
	     (if end
		 (if count
		     (if key
			 (|nsubstitute-if-not seq-type=list from-end=true end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|nsubstitute-if-not seq-type=list from-end=true end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|nsubstitute-if-not seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|nsubstitute-if-not seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|nsubstitute-if-not seq-type=list from-end=true end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|nsubstitute-if-not seq-type=list from-end=true end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|nsubstitute-if-not seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|nsubstitute-if-not seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))
	     (if end
		 (if count
		     (if key
			 (|nsubstitute-if-not seq-type=list from-end=false end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|nsubstitute-if-not seq-type=list from-end=false end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|nsubstitute-if-not seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|nsubstitute-if-not seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|nsubstitute-if-not seq-type=list from-end=false end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|nsubstitute-if-not seq-type=list from-end=false end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|nsubstitute-if-not seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|nsubstitute-if-not seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))))
	((simple-string-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=simple-string from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=simple-string from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=simple-string count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=simple-string count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=simple-string from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=simple-string from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=simple-string count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=simple-string count=nil key=identity|
		      newitem predicate sequence start end)))))
	((simple-vector-p sequence)
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=simple-vector from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=simple-vector from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=simple-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=simple-vector count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=simple-vector from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=simple-vector from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=simple-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=simple-vector count=nil key=identity|
		      newitem predicate sequence start end)))))
	(t
	 (when (null end)
	   (setf end (length sequence)))
	 (if from-end
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=general-vector from-end=true count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=general-vector from-end=true count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=general-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=general-vector count=nil key=identity|
		      newitem predicate sequence start end)))
	     (if count
		 (if key
		     (|nsubstitute-if-not seq-type=general-vector from-end=false count=other key=other|
		      newitem predicate sequence start end count key)
		     (|nsubstitute-if-not seq-type=general-vector from-end=false count=other key=identity|
		      newitem predicate sequence start end count))
		 (if key
		     (|nsubstitute-if-not seq-type=general-vector count=nil key=other|
		      newitem predicate sequence start end key)
		     (|nsubstitute-if-not seq-type=general-vector count=nil key=identity|
		      newitem predicate sequence start end)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function substitute

(defun |substitute seq-type=list end=nil test=eql count=nil key=identity|
    (newitem olditem list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eql olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test=eql count=nil key=other|
    (newitem olditem list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eql olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=eql count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test=eq count=nil key=identity|
    (newitem olditem list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eq olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test=eq count=nil key=other|
    (newitem olditem list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=eq count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eq olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=eq count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test=other count=nil key=identity|
    (newitem olditem list start test)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall test olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test=other count=nil key=other|
    (newitem olditem list start test key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=other count=other key=identity|
    (newitem olditem list start test count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall test olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test=other count=other key=other|
    (newitem olditem list start test count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=eql count=nil key=identity|
    (newitem olditem list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eql olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=eql count=nil key=other|
    (newitem olditem list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=eql count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eql olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=eql count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=eq count=nil key=identity|
    (newitem olditem list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eq olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=eq count=nil key=other|
    (newitem olditem list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=eq count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eq olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=eq count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=other count=nil key=identity|
    (newitem olditem list start test-not)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=nil test-not=other count=nil key=other|
    (newitem olditem list start test-not key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=other count=other key=identity|
    (newitem olditem list start test-not count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=nil test-not=other count=other key=other|
    (newitem olditem list start test-not count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute seq-type=list end=other test=eql count=nil key=identity|
    (newitem olditem list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eql olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test=eql count=nil key=other|
    (newitem olditem list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=eql count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eql olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=eql count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eql olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test=eq count=nil key=identity|
    (newitem olditem list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eq olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test=eq count=nil key=other|
    (newitem olditem list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=eq count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eq olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=eq count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (eq olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test=other count=nil key=identity|
    (newitem olditem list start end test)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall test olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test=other count=nil key=other|
    (newitem olditem list start end test key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=other count=other key=identity|
    (newitem olditem list start end test count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall test olditem (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test=other count=other key=other|
    (newitem olditem list start end test count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall test olditem (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=eql count=nil key=identity|
    (newitem olditem list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eql olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=eql count=nil key=other|
    (newitem olditem list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=eql count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eql olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=eql count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eql olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=eq count=nil key=identity|
    (newitem olditem list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eq olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=eq count=nil key=other|
    (newitem olditem list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=eq count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eq olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=eq count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (eq olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=other count=nil key=identity|
    (newitem olditem list start end test-not)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list end=other test-not=other count=nil key=other|
    (newitem olditem list start end test-not key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=other count=other key=identity|
    (newitem olditem list start end test-not count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (funcall test-not olditem (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=false end=other test-not=other count=other key=other|
    (newitem olditem list start end test-not count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (not (funcall test-not olditem (funcall key (car remaining))))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=eql count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=eq count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=eq count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=other count=other key=identity|
    (newitem olditem list start test count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test=other count=other key=other|
    (newitem olditem list start test count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=eql count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=eql count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=eq count=other key=identity|
    (newitem olditem list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=eq count=other key=other|
    (newitem olditem list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=other count=other key=identity|
    (newitem olditem list start test-not count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test-not olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=nil test-not=other count=other key=other|
    (newitem olditem list start test-not count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test-not olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=eql count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=eql count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=eq count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=eq count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=other count=other key=identity|
    (newitem olditem list start end test count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test olditem (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test=other count=other key=other|
    (newitem olditem list start end test count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test olditem (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=eql count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=eql count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eql olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=eq count=other key=identity|
    (newitem olditem list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=eq count=other key=other|
    (newitem olditem list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (eq olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=other count=other key=identity|
    (newitem olditem list start end test-not count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test-not olditem (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute seq-type=list from-end=true end=other test-not=other count=other key=other|
    (newitem olditem list start end test-not count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall test-not olditem (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun substitute
    (newitem olditem sequence &rest args &key from-end test test-not (start 0) end count key)
  (assert (or (null test) (null test-not)))
  (cond ((listp sequence)
	 (cond (test
		(cond ((or (eq test #'eql) (eq test 'eql))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=true end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=false end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))))
		      ((or (eq test #'eq) (eq test 'eq))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=true end=other test=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=true end=nil test=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eq count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=false end=other test=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=false end=nil test=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eq count=nil key=identity|
					newitem olditem sequence start))))))
		      (t
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test=other count=other key=other|
					newitem olditem sequence start end test count key)
				       (|substitute seq-type=list from-end=true end=other test=other count=other key=identity|
					newitem olditem sequence start end test count))
				   (if key
				       (|substitute seq-type=list end=other test=other count=nil key=other|
					newitem olditem sequence start end test key)
				       (|substitute seq-type=list end=other test=other count=nil key=identity|
					newitem olditem sequence start end test)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test=other count=other key=other|
					newitem olditem sequence start test count key)
				       (|substitute seq-type=list from-end=true end=nil test=other count=other key=identity|
					newitem olditem sequence start test count))
				   (if key
				       (|substitute seq-type=list end=nil test=other count=nil key=other|
					newitem olditem sequence start test key)
				       (|substitute seq-type=list end=nil test=other count=nil key=identity|
					newitem olditem sequence start test))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test=other count=other key=other|
					newitem olditem sequence start end test count key)
				       (|substitute seq-type=list from-end=false end=other test=other count=other key=identity|
					newitem olditem sequence start end test count))
				   (if key
				       (|substitute seq-type=list end=other test=other count=nil key=other|
					newitem olditem sequence start end test key)
				       (|substitute seq-type=list end=other test=other count=nil key=identity|
					newitem olditem sequence start test end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test=other count=other key=other|
					newitem olditem sequence start test count key)
				       (|substitute seq-type=list from-end=false end=nil test=other count=other key=identity|
					newitem olditem sequence start test count))
				   (if key
				       (|substitute seq-type=list end=nil test=other count=nil key=other|
					newitem olditem sequence start test key)
				       (|substitute seq-type=list end=nil test=other count=nil key=identity|
					newitem olditem sequence start test))))))))
	       (test-not
		(cond ((or (eq test-not #'eql) (eq test-not 'eql))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test-not=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=true end=other test-not=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test-not=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test-not=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test-not=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=true end=nil test-not=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test-not=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test-not=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=false end=other test-not=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test-not=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test-not=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test-not=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=false end=nil test-not=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test-not=eql count=nil key=identity|
					newitem olditem sequence start))))))
		      ((or (eq test-not #'eq) (eq test-not 'eq))
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test-not=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=true end=other test-not=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test-not=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test-not=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test-not=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=true end=nil test-not=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test-not=eq count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test-not=eq count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=false end=other test-not=eq count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test-not=eq count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test-not=eq count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test-not=eq count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=false end=nil test-not=eq count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=eq count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test-not=eq count=nil key=identity|
					newitem olditem sequence start))))))
		      (t
		       (if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test-not=other count=other key=other|
					newitem olditem sequence start end test-not count key)
				       (|substitute seq-type=list from-end=true end=other test-not=other count=other key=identity|
					newitem olditem sequence start end test-not count))
				   (if key
				       (|substitute seq-type=list end=other test-not=other count=nil key=other|
					newitem olditem sequence start end test-not key)
				       (|substitute seq-type=list end=other test-not=other count=nil key=identity|
					newitem olditem sequence start end test-not)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test-not=other count=other key=other|
					newitem olditem sequence start test-not count key)
				       (|substitute seq-type=list from-end=true end=nil test-not=other count=other key=identity|
					newitem olditem sequence start test-not count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=other count=nil key=other|
					newitem olditem sequence start test-not key)
				       (|substitute seq-type=list end=nil test-not=other count=nil key=identity|
					newitem olditem sequence start test-not))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test-not=other count=other key=other|
					newitem olditem sequence start end test-not count key)
				       (|substitute seq-type=list from-end=false end=other test-not=other count=other key=identity|
					newitem olditem sequence start end test-not count))
				   (if key
				       (|substitute seq-type=list end=other test-not=other count=nil key=other|
					newitem olditem sequence start end test-not key)
				       (|substitute seq-type=list end=other test-not=other count=nil key=identity|
					newitem olditem sequence start end test-not)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test-not=other count=other key=other|
					newitem olditem sequence start test-not count key)
				       (|substitute seq-type=list from-end=false end=nil test-not=other count=other key=identity|
					newitem olditem sequence start test-not count))
				   (if key
				       (|substitute seq-type=list end=nil test-not=other count=nil key=other|
					newitem olditem sequence start test-not key)
				       (|substitute seq-type=list end=nil test-not=other count=nil key=identity|
					newitem olditem sequence start test-not))))))))
	       (t
		(if from-end
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=true end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=true end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=true end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))
			   (if end
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=other test=eql count=other key=other|
					newitem olditem sequence start end count key)
				       (|substitute seq-type=list from-end=false end=other test=eql count=other key=identity|
					newitem olditem sequence start end count))
				   (if key
				       (|substitute seq-type=list end=other test=eql count=nil key=other|
					newitem olditem sequence start end key)
				       (|substitute seq-type=list end=other test=eql count=nil key=identity|
					newitem olditem sequence start end)))
			       (if count
				   (if key
				       (|substitute seq-type=list from-end=false end=nil test=eql count=other key=other|
					newitem olditem sequence start count key)
				       (|substitute seq-type=list from-end=false end=nil test=eql count=other key=identity|
					newitem olditem sequence start count))
				   (if key
				       (|substitute seq-type=list end=nil test=eql count=nil key=other|
					newitem olditem sequence start key)
				       (|substitute seq-type=list end=nil test=eql count=nil key=identity|
					newitem olditem sequence start))))))))
	(t
	 (apply #'nsubstitute newitem olditem (copy-seq sequence) args))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function substitute-if

(defun |substitute-if seq-type=list end=nil count=nil key=identity|
    (newitem predicate list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if seq-type=list end=nil count=nil key=other|
    (newitem predicate list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if seq-type=list from-end=false end=nil count=other key=identity|
    (newitem predicate list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if seq-type=list from-end=false end=nil count=other key=other|
    (newitem predicate list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if seq-type=list end=other count=nil key=identity|
    (newitem predicate list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if seq-type=list end=other count=nil key=other|
    (newitem predicate list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if seq-type=list from-end=false end=other count=other key=identity|
    (newitem predicate list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if seq-type=list from-end=false end=other count=other key=other|
    (newitem predicate list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  when (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if seq-type=list from-end=true end=nil count=other key=identity|
    (newitem predicate list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if seq-type=list from-end=true end=nil count=other key=other|
    (newitem predicate list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if seq-type=list from-end=true end=other count=other key=identity|
    (newitem predicate list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (car reversed))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if seq-type=list from-end=true end=other count=other key=other|
    (newitem predicate list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (funcall key (car reversed)))
		   (progn (push newitem result-tail)
			  (decf count))
		   (push (car reversed) result-tail))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun substitute-if
    (newitem predicate sequence &rest args &key from-end (start 0) end count key)
  (cond ((listp sequence)
	 (if from-end
	     (if end
		 (if count
		     (if key
			 (|substitute-if seq-type=list from-end=true end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|substitute-if seq-type=list from-end=true end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|substitute-if seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|substitute-if seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|substitute-if seq-type=list from-end=true end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|substitute-if seq-type=list from-end=true end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|substitute-if seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|substitute-if seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))
	     (if end
		 (if count
		     (if key
			 (|substitute-if seq-type=list from-end=false end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|substitute-if seq-type=list from-end=false end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|substitute-if seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|substitute-if seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|substitute-if seq-type=list from-end=false end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|substitute-if seq-type=list from-end=false end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|substitute-if seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|substitute-if seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))))
	(t (apply #'nsubstitute-if newitem predicate (copy-seq sequence) args))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function substitute-if-not

(defun |substitute-if-not seq-type=list end=nil count=nil key=identity|
    (newitem predicate list start)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  unless (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if-not seq-type=list end=nil count=nil key=other|
    (newitem predicate list start key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=false end=nil count=other key=identity|
    (newitem predicate list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  unless (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=false end=nil count=other key=other|
    (newitem predicate list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop count)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining)))
    (cdr result)))

(defun |substitute-if-not seq-type=list end=other count=nil key=identity|
    (newitem predicate list start end)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  unless (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if-not seq-type=list end=other count=nil key=other|
    (newitem predicate list start end key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=false end=other count=other key=identity|
    (newitem predicate list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  unless (funcall predicate (car remaining))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=false end=other count=other key=other|
    (newitem predicate list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    ;; We can't use loop for ... on, becaue it uses atom for testing the end
    (loop until (endp remaining)
	  until (zerop end-start)
	  until (zerop count)
	  unless (funcall predicate (funcall key (car remaining)))
	    do (setf (cdr last) (cons newitem (cdr remaining)))
	       (decf count)
	  else
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	  do (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf end-start))
    (when (plusp end-start)
      (error 'invalid-end-index
	     :datum end
	     :expected-type `(integer 0 ,(- end end-start))
	     :in-sequence list))
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=true end=nil count=other key=identity|
    (newitem predicate list start count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=true end=nil count=other key=other|
    (newitem predicate list start count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    do (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=true end=other count=other key=identity|
    (newitem predicate list start end count)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      ;; nreverse it again and count
      (loop until (null reversed)
	    while (plusp count)
	    do (if (funcall predicate (car reversed))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun |substitute-if-not seq-type=list from-end=true end=other count=other key=other|
    (newitem predicate list start end count key)
  (let* ((remaining list)
	 (result (list nil))
	 (result-tail '())
	 (last result)
	 (start-bis start)
	(end-start (- end start)))
    ;; skip a prefix indicated by start
    (loop until (zerop start-bis)
	  until (endp remaining)
	  do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	     (setf last (cdr last))
	     (setf remaining (cdr remaining))
	     (decf start-bis))
    (unless (zerop start-bis)
      (error 'invalid-start-index
	     :datum start
	     :expected-type `(integer 0 ,(- start start-bis))
	     :in-sequence list))
    (let ((reversed '()))
      ;; nreverse the remaining list
      (loop until (endp remaining)
	    while (plusp end-start)
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	       (setf last (cdr last))
	       (decf end-start)
	       (let ((temp (cdr remaining)))
		 (setf (cdr remaining) reversed)
		 (setf reversed remaining)
		 (setf remaining temp)))
      (when (plusp end-start)
	(error 'invalid-end-index
	       :datum end
	       :expected-type `(integer 0 ,(- end end-start))
	       :in-sequence list))
      (setf result-tail remaining)
      (loop until (null reversed)
	    while (plusp count)
	    do (setf (cdr last) (cons (car remaining) (cdr remaining)))
	       (setf last (cdr last))
	       (if (funcall predicate (funcall key (car reversed)))
		   (push (car reversed) result-tail)
		   (progn (push newitem result-tail)
			  (decf count)))
	       (let ((temp (cdr reversed)))
		 (setf (cdr reversed) remaining)
		 (setf remaining reversed)
		 (setf reversed temp))))
    (setf (cdr last) result-tail)
    (cdr result)))

(defun substitute-if-not
    (newitem predicate sequence &rest args &key from-end (start 0) end count key)
  (cond ((listp sequence)
	 (if from-end
	     (if end
		 (if count
		     (if key
			 (|substitute-if-not seq-type=list from-end=true end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|substitute-if-not seq-type=list from-end=true end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|substitute-if-not seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|substitute-if-not seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|substitute-if-not seq-type=list from-end=true end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|substitute-if-not seq-type=list from-end=true end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|substitute-if-not seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|substitute-if-not seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))
	     (if end
		 (if count
		     (if key
			 (|substitute-if-not seq-type=list from-end=false end=other count=other key=other|
			  newitem predicate sequence start end count key)
			 (|substitute-if-not seq-type=list from-end=false end=other count=other key=identity|
			  newitem predicate sequence start end count))
		     (if key
			 (|substitute-if-not seq-type=list end=other count=nil key=other|
			  newitem predicate sequence start end key)
			 (|substitute-if-not seq-type=list end=other count=nil key=identity|
			  newitem predicate sequence start end)))
		 (if count
		     (if key
			 (|substitute-if-not seq-type=list from-end=false end=nil count=other key=other|
			  newitem predicate sequence start count key)
			 (|substitute-if-not seq-type=list from-end=false end=nil count=other key=identity|
			  newitem predicate sequence start count))
		     (if key
			 (|substitute-if-not seq-type=list end=nil count=nil key=other|
			  newitem predicate sequence start key)
			 (|substitute-if-not seq-type=list end=nil count=nil key=identity|
			  newitem predicate sequence start))))))
	(t
	 (apply #'nsubstitute-if-not newitem predicate (copy-seq sequence) args))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function reverse

(defun |reverse seq-type=list|
    (list)
  (let ((result '())
	(remaining list))
    (loop until (endp remaining)
	  do (push (pop remaining) result))
    result))

(defun |reverse seq-type=general-vector|
    (vector)
  (let ((result (make-array (length vector)
			    :element-type (array-element-type vector)))
	(length (length vector)))
    (loop for i from 0 below length
	  do (setf (aref result i) (aref vector (- length i 1))))
    result))

(defun |reverse seq-type=simple-vector|
    (vector)
  (let ((result (make-array (length vector)
			    :element-type (array-element-type vector)))
	(length (length vector)))
    (loop for i from 0 below length
	  do (setf (svref result i) (svref vector (- length i 1))))
    result))

(defun |reverse seq-type=simple-string|
    (string)
  (let ((result (make-array (length string)
			    :element-type (array-element-type string)))
	(length (length string)))
    (loop for i from 0 below length
	  do (setf (schar result i) (schar string (- length i 1))))
    result))

(defun reverse (sequence)
  (cond ((listp sequence)
	 (|reverse seq-type=list| sequence))
	((simple-string-p sequence)
	 (|reverse seq-type=simple-string| sequence))
	((simple-vector-p sequence)
	 (|reverse seq-type=simple-vector| sequence))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function nreverse

;;; Fixme, don't use endp
(defun |nreverse seq-type=list|
    (list)
  (let ((result '())
	(remaining list))
    (loop until (endp remaining)
	  do (let ((temp (cdr remaining)))
	       (setf (cdr remaining) result)
	       (setf result remaining)
	       (setf remaining temp)))
    result))

(defun |nreverse seq-type=general-vector|
    (vector)
  (let ((length (length vector)))
    (loop for i from 0 below (floor length 2)
	  do (rotatef (aref vector i) (aref vector (- length i 1)))))
  vector)

(defun |nreverse seq-type=simple-vector|
    (vector)
  (let ((length (length vector)))
    (loop for i from 0 below (floor length 2)
	  do (rotatef (svref vector i) (svref vector (- length i 1)))))
  vector)

(defun |nreverse seq-type=simple-string|
    (string)
  (let ((length (length string)))
    (loop for i from 0 below (floor length 2)
	  do (rotatef (schar string i) (schar string (- length i 1)))))
  string)

(defun nreverse (sequence)
  (cond ((listp sequence)
	 (|nreverse seq-type=list| sequence))
	((simple-string-p sequence)
	 (|nreverse seq-type=simple-string| sequence))
	((simple-vector-p sequence)
	 (|nreverse seq-type=simple-vector| sequence))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Function mismatch

;;; FIXME: incomplete non-working definition at the moment

;;; Check whether a list is circular.
(defun circular-list-p (list)
  (if (null list)
      nil
      (loop with fast = (cdr list)
	    with slow = list
	    until (atom fast)
	    when (eq fast slow) return t
	    do (setf fast (cdr fast))
	    until (atom fast)
	    do (setf fast (cdr fast))
	    do (setf slow (cdr slow)))))

;;; Check whether a non-circular list is a dotted list
(defun dotted-list-p (list)
  (and (not (null list))
       (not (null (cdr (last list))))))

;;; Check whether a list is a proper list.
(defun proper-list-p (list)
  (or (null list)
      (and (not (circular-list-p list))
	   (not (dotted-list-p list)))))

;;; Convert a list to a vector.  Signal an error if the list is not
;;; a proper list. 
(defun convert-list-to-vector (name list)
  (if (proper-list-p list)
      (coerce list 'vector)
      (error 'must-be-proper-list
	     :name name
	     :datum list)))

(defun |mismatch seq-type-1=vector seq-type-2=vector from-end=false|
    (sequence-1 sequence-2 key test start1 start2 end1 end2)
  (loop for i1 from start1 below end1
	for i2 from start2 below end2
	unless (funcall test (funcall key (aref sequence-1 i1)) (funcall key (aref sequence-2 i2)))
	return i1
	finally (return (if (= (- end2 start2) (- end1 start1))
			    nil
			    i1))))
    
(defun |mismatch seq-type-1=vector seq-type-2=vector from-end=true|
    (sequence-1 sequence-2 key test start1 start2 end1 end2)
  (loop for i1 downfrom (1- end1) to start1
	for i2 downfrom (1- end2) to start2
	unless (funcall test (funcall key (aref sequence-1 i1)) (funcall key (aref sequence-2 i2)))
	return (1+ i1)
	finally (return (if (= (- end2 start2) (- end1 start1))
			    nil
			    (1+ i1)))))

(defun mismatch (sequence-1 sequence-2
		 &key key test test-not start1 start2 end1 end2 from-end)
  (declare (ignore sequence-1 sequence-2 key test test-not start1 start2 end1 end2 from-end))
  nil)
