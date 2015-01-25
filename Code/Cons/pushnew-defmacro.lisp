(cl:in-package #:sicl-cons)

(defmacro pushnew (item place
		   &environment env
		   &rest args
		   &key
		   (key nil key-p)
		   (test nil test-p)
		   (test-not nil test-not-p))
  (declare (ignorable test test-not))
  (if (and test-p test-not-p)
      (progn (warn 'warn-both-test-and-test-not-given
		   :name 'pushnew)
	     `(error 'both-test-and-test-not-given :name 'pushnew))
      (let ((item-var (gensym)))
	(multiple-value-bind (vars vals store-vars writer-form reader-form)
	    (get-setf-expansion place env)
	  `(let ((,item-var ,item)
		 ,@(mapcar #'list vars vals)
		 ,@(make-bindings args))
	     ,@(if key-p `((declare (ignorable key))) `())
	     (let ((,(car store-vars) ,reader-form))
	       ,(if key
		    (if test-p
			`(unless (|member test=other key=other|
				  'pushnew
				  (funcall key ,item-var)
				  ,(car store-vars)
				  test
				  key)
			   (push ,item-var ,(car store-vars)))
			(if test-not-p
			    `(unless (|member test-not=other key=other|
				      'pushnew
				      (funcall key ,item-var)
				      ,(car store-vars)
				      test-not
				      key)
			       (push ,item-var ,(car store-vars)))
			    `(unless (|member test=eql key=other|
				      'pushnew
				      (funcall key ,item-var)
				      ,(car store-vars)
				      key)
			       (push ,item-var ,(car store-vars)))))
		    (if test-p
			`(unless (|member test=other key=identity|
				  'pushnew
				  ,item-var
				  ,(car store-vars)
				  test)
			   (push ,item-var ,(car store-vars)))
			(if test-not-p
			    `(unless (|member test-not=other key=identity|
				      'pushnew
				      ,item-var
				      ,(car store-vars)
				      test-not)
			       (push ,item-var ,(car store-vars)))
			    `(unless (|member test=eql key=identity|
				      'pushnew
				      ,item-var
				      ,(car store-vars))
			       (push ,item-var ,(car store-vars))))))
	       ,writer-form))))))
