;; divide by 2 above 2^14
(defun count-from-end-with-length-2 (x list length)
  (declare (optimize (speed 3) (debug 0) (safety 0) (compilation-speed 0)))
  (declare (type fixnum length))
  (let ((count 0))
    (declare (type fixnum count))
    (flet ((process (elem)
	     (when (eql elem x)
	       (incf count))))
      (labels ((recursive-traverse (rest n)
		 (declare (type fixnum n))
		 (when (> n 0)
		     (recursive-traverse (cdr rest) (1- n))
		     (process (car rest))))
	       (traverse (rest n)
		 (declare (type fixnum n))
		 (cond ((<= n 16384)
			(recursive-traverse rest n))
		       (t
			(let* ((n/2 (ash n -1))
			       (half (nthcdr n/2 list)))
			  (traverse half (- n n/2))
			  (traverse list n/2))))))
	(traverse list length)))
    count))

(defun count-from-end-with-length-2-macro (x list length)
  (declare (optimize (speed 3) (debug 0) (safety 0) (compilation-speed 0)))
  (declare (type fixnum length))
  (let ((count 0))
    (declare (type fixnum count))
    (flet ((process (elem)
	     (when (eql elem x)
	       (incf count))))
      (macrolet ((divide (rest length k)
		   (let* ((n (ash 1 k))
			  (gensyms (loop repeat n collect (gensym)))
			  (f (gensym)))
		     `(let ((,f (ash length (- ,k)))
			    (,(car gensyms) ,rest))
			(let* ,(loop
				 for gensym1 in gensyms
				 for gensym2 in (cdr gensyms)
				 collect `(,gensym2 (nthcdr ,f ,gensym1)))
			  (traverse
			   (nthcdr ,f ,(car (last gensyms)))
			   (- ,length (ash ,f ,k)))
			  ,@(loop
			      for gensym in (reverse gensyms)
			      collect `(traverse ,gensym ,f)))))))
	(labels ((recursive-traverse (rest n)
		 (declare (type fixnum n))
		 (when (> n 0)
		     (recursive-traverse (cdr rest) (1- n))
		     (process (car rest))))
		 (traverse (rest n)
		   (declare (type fixnum n))
		   (cond ((< n 10000)
			  (recursive-traverse rest n))
			 (t (divide rest length 1)))))
	  (traverse list length))))
    count))

(defun reverse-count-2 (x list)
  (count-from-end-with-length-2 x list (length list)))

(defun reverse-count-2-macro (x list)
  (count-from-end-with-length-2-macro x list (length list)))
