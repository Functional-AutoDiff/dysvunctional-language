(define ((tagged-list? tag) thing)
  (and (pair? thing)
       (eq? (car thing) tag)))

(define (constant? thing)
  (or (number? thing)
      (slad-bundle? thing)
      (null? thing)))

(define (constant-value thing)
  thing)

(define (definition? form)
  (and (pair? form)
       (eq? (car form) 'define)))

(define (definiendum definition)
  (if (pair? (cadr definition))
      (caadr definition)
      (cadr definition)))

(define (definiens definition)
  (if (pair? (cadr definition))
      `(lambda ,(cdadr definition)
	 ,@(cddr definition))
      (caddr definition)))

(define (variable? thing)
  (symbol? thing))
(define variable<? symbol<?)

(define pair-form? (tagged-list? 'cons))
(define car-subform cadr)
(define cdr-subform caddr)
(define (make-pair-form car-subform cdr-subform)
  `(cons ,car-subform ,cdr-subform))

(define make-slad-pair cons)
(define slad-pair? pair?)
(define slad-car car)
(define slad-cdr cdr)
(define slad-empty-list? null?)

(define lambda-form? (tagged-list? 'lambda))
(define lambda-formal cadr)
(define lambda-body caddr)
(define (make-lambda-form formal body)
  `(lambda ,formal ,body))

(define (application? thing)
  (and (pair? thing)
       (not (pair-form? thing))
       (not (lambda-form? thing))))
(define operator-subform car)
(define operand-subform cadr)
(define (make-application operator-form operand-form)
  `(,operator-form ,operand-form))

(define-structure (slad-closure safe-accessors (constructor %make-slad-closure))
  formal
  body
  env)

(define (env-slice env variables)
  (make-env
   (filter (lambda (binding)
	     (memq (car binding) variables))
	   (env-bindings env))))

;;; To keep environments in canonical form, closures only keep the
;;; variables they want.
(define (make-slad-closure formal body env)
  (let ((free (free-variables `(lambda ,formal ,body))))
    (%make-slad-closure formal body (env-slice env free))))

(define-structure (slad-primitive safe-accessors)
  name
  implementation)

(define slad-real? real?)

(define-structure (slad-bundle safe-accessors)
  primal tangent)


(define (slad-map f object . objects)
  (cond ((slad-closure? object)
	 (make-slad-closure
	  (slad-closure-formal object)
	  (apply slad-exp-map f (slad-closure-body object) (map slad-closure-body objects))
	  (apply f (slad-closure-env object) (map slad-closure-env objects))))
	((env? object)
	 (apply slad-env-map f object objects))
	((slad-pair? object)
	 (make-slad-pair (apply f (slad-car object) (map slad-car objects))
			 (apply f (slad-cdr object) (map slad-cdr objects))))
	((slad-bundle? object)
	 (make-slad-bundle (apply f (slad-primal object) (map slad-primal objects))
			   (apply f (slad-tangent object) (map slad-tangent objects))))
	(else
	 object)))

(define (slad-exp-map f form . forms)
  (cond ((constant? form)
	 (apply f form forms))
	((variable? form) form)
	((pair-form? form)
	 (make-pair-form (apply slad-exp-map f (car-subform form) (map car-subform forms))
			 (apply slad-exp-map f (cdr-subform form) (map cdr-subform forms))))
	((lambda-form? form)
	 (make-lambda-form (lambda-formal form)
			   (apply slad-exp-map f (lambda-body form) (map lambda-body forms))))
	((application? form)
	 (make-application (apply slad-exp-map f (operator-subform form) (map operator-subform forms))
			   (apply slad-exp-map f (operand-subform form) (map operand-subform forms))))
	(else
	 (error "Invalid expression type" form forms))))

(define (slad-copy object)
  (cond ((slad-primitive? object)
	 (make-slad-primitive (slad-primitive-name object)
			      (slad-primitive-implementation object)))
	(else
	 (slad-map slad-copy object))))

(define (free-variables form)
  (cond ((constant? form)
	 '())
	((variable? form)
	 (list form))
	((pair-form? form)
	 (lset-union equal? (free-variables (car-subform form))
		     (free-variables (cdr-subform form))))
	((lambda-form? form)
	 (lset-difference equal? (free-variables (lambda-body form))
			  (free-variables (lambda-formal form))))
	((pair? form)
	 (lset-union equal? (free-variables (car form))
		     (free-variables (cdr form))))
	(else
	 (error "Invalid expression type" form forms))))
