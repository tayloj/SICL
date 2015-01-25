(cl:in-package #:sicl-extrinsic-hir-compiler)

(defparameter *trace-funcall* nil)

(defparameter *depth* 0)

(defun traced-funcall (function &rest arguments)
  (if *trace-funcall*
      (let* ((entries (sicl-simple-environment::function-entries *environment*))
	     (entry (find function entries
			  :test #'eq
			  :key (lambda (entry)
				 (car (sicl-simple-environment::function-cell entry)))))
	     (name (if (null entry)
		       "???"
		       (sicl-simple-environment::name entry)))
	     (result nil))
	(loop repeat *depth*
	      do (format *trace-output* " "))
	(format *trace-output*
		"calling ~s with arguments: ~s~%" name arguments)
	(let ((*depth* (1+ *depth*)))
	  (setq result (multiple-value-list (apply function arguments))))
	(loop repeat *depth*
	      do (format *trace-output* " "))
	(format *trace-output*
		"~s returned: ~s~%" name result)
	(apply #'values result))
      (apply function arguments)))

    
	
    
	 
