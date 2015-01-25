(cl:in-package #:sicl-clos)

(defun ensure-generic-function-using-class-null
    (generic-function
     function-name
     &rest
       all-keyword-arguments
     &key
       environment
       (generic-function-class
	(sicl-environment:find-class 'standard-generic-function environment))
       (method-class nil method-class-p)
     &allow-other-keys)
  (declare (ignore generic-function))
  (cond ((symbolp generic-function-class)
	 (let ((class (sicl-environment:find-class generic-function-class
						   environment)))
	   (when (null class)
	     (error "no such generic-function-class ~s"
		    generic-function-class))
	   (setf generic-function-class class)))
	((typep generic-function-class 'class)
	 nil)
	(t
	 (error "generic function class must be a class or a name")))
  (when method-class-p
    (cond ((symbolp method-class)
	   (let ((class (sicl-environment:find-class method-class
						     environment)))
	     (when (null class)
	       (error "no such method class ~s" method-class))
	     (setf method-class class)))
	  ((typep method-class 'class)
	   nil)
	  (t
	   (error "method class must be a class or a name"))))
  (let ((remaining-keys (copy-list all-keyword-arguments)))
    (loop while (remf remaining-keys :generic-function-class))
    (loop while (remf remaining-keys :environment))
    (setf (sicl-environment:fdefinition function-name environment)
	  (if method-class-p
	      (apply #'make-instance generic-function-class
		     ;; The AMOP does
		     :name function-name
		     :method-class method-class
		     remaining-keys)
	      (apply #'make-instance generic-function-class
		     :name function-name
		     remaining-keys)))))

(defun ensure-generic-function-using-class-generic-function
    (generic-function
     function-name
     &rest
       all-keyword-arguments
     &key
       environment
       (generic-function-class
	(sicl-environment:find-class 'standard-generic-function environment))
       (method-class nil method-class-p)
     &allow-other-keys)
  (declare (ignore function-name))
  (cond ((symbolp generic-function-class)
	 (let ((class (sicl-environment:find-class generic-function-class
						   environment)))
	   (when (null class)
	     (error "no such generic-function-class ~s"
		    generic-function-class))
	   (setf generic-function-class class)))
	((typep generic-function-class 'class)
	 nil)
	(t
	 (error "generic function class must be a class or a name")))
  (unless (eq generic-function-class (class-of generic-function))
    (error "classes don't agree"))
  (when method-class-p
    (cond ((symbolp method-class)
	   (let ((class (sicl-environment:find-class method-class
						     environment)))
	     (when (null class)
	       (error "no such method class ~s" method-class))
	     (setf method-class class)))
	  ((typep method-class 'class)
	   nil)
	  (t
	   (error "method class must be a class or a name"))))
  (let ((remaining-keys (copy-list all-keyword-arguments)))
    (loop while (remf remaining-keys :generic-function-class))
    (loop while (remf remaining-keys :environment))
    (if method-class-p
	(apply #'reinitialize-instance generic-function
	       :method-class method-class
	       remaining-keys)
	(apply #'reinitialize-instance generic-function
	       remaining-keys)))
  generic-function)
