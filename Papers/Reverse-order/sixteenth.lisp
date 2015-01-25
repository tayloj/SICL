(defun find-from-end-4 (x list)
  (declare (optimize (speed 3) (debug 0) (safety 0)))
  (declare (type list list))
  (labels ((recursive (x list n)
	     (declare (type fixnum n))
	     (if (zerop n)
		 nil
		 (progn (recursive x (cdr list) (1- n))
			(when (eq x (car list))
			  (return-from find-from-end-4 x))))))
    (labels ((aux (x list n)
	     (declare (type fixnum n))
	       (if (< n 10000)
		   (recursive x list n)
		   (let* ((m (ash n -4))
			  (sublist (nthcdr m list)))
		     (aux x sublist (- n m))
		     (aux x list m)))))
      (aux x list (length list)))))
