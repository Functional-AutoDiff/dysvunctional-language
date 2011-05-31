(declare (usual-integrations))
;;;; Compilation with MIT Scheme

(define (fol->mit-scheme program #!optional output-base)
  (if (default-object? output-base)
      (set! output-base "frobnozzle"))
  (let* ((output `((declare (usual-integrations))
                   ,(internalize-definitions program)))
         (output-file (pathname-new-type output-base "fol-scm")))
    (with-output-to-file output-file
      (lambda ()
        (for-each (lambda (form)
                    (pp form)
                    (newline)) output)))
    (fluid-let ((sf/default-syntax-table fol-environment))
      (cf output-file))))

;;; Note: The semantics of a flonumized FOL program are different than
;;; those of one executed straight, because of differences in the
;;; interpretation of numbers.
(define (fol->floating-mit-scheme program #!optional output-base)
  (fol->mit-scheme (flonumize program) output-base))

(define (run-mit-scheme #!optional output-base)
  (if (default-object? output-base)
      (set! output-base "frobnozzle"))
  (load output-base fol-environment))

(define my-path (->namestring (self-relatively current-load-pathname)))

(define (fol->standalone-mit-scheme program #!optional output-base)
  (if (default-object? output-base)
      (set! output-base "frobnozzle"))
  (let* ((srfi-11 (read-source (string-append my-path "srfi-11.scm")))
         (runtime (read-source (string-append my-path "runtime.scm")))
         (output
          `(,@srfi-11                   ; includes usual-integrations
            ,@(cdr runtime)             ; remove usual-integrations
            ,(internalize-definitions program)))
         (output-file (pathname-new-type output-base "fol-scm")))
    (with-output-to-file output-file
      (lambda ()
        (for-each (lambda (form)
                    (pp form)
                    (newline)) output)))
    (cf output-file)))

(define (internalize-definitions program)
  (if (begin-form? program)
      `(let () ,@(cdr program))
      program))

;;; Convert all numeric operations to MIT Scheme primitives that
;;; assume floating point arguments, instead of the generic
;;; operations.  This saves on dispatches, but arguably changes the
;;; semantics (in particular, exact arithmetic disappears).
(define (flonumize program)
  (define floating-versions
    (cons (cons 'atan 'flo:atan2)
          (map (lambda (name)
                 (cons name (symbol 'flo: name)))
               '(+ - * / < = > <= >= abs exp log sin cos tan asin acos
                   sqrt expt zero? negative? positive?))))
  (define (arithmetic? expr)
    (and (pair? expr)
         (assq (car expr) floating-versions)))
  (define (real-call? expr)
    (and (pair? expr)
         (eq? (car expr) 'real)))
  (define read-real-call? (tagged-list? 'read-real))
  (define (replace thing)
    (cdr (assq thing floating-versions)))
  (define (loop expr)
    (cond ((number? expr) (exact->inexact expr))
          ((access? expr) `(,(car expr) ,(loop (cadr expr)) ,@(cddr expr)))
          ((arithmetic? expr)
           `(,(replace (car expr)) ,@(map loop (cdr expr))))
          ((real-call? expr)
           (loop (cadr expr)))
          ((read-real-call? expr)
           `(exact->inexact ,expr))
          ((pair? expr) (map loop expr))
          (else expr)))
  (loop program))

;;; Manually integrating arithmetic to avoid binding variables to hold
;;; intermediate floating point values, in the hopes that this will
;;; improve compiled floating point performance in MIT Scheme.  It did
;;; not, however, appear to have worked.
(define integrate-arithmetic
  (let ((arithmetic?
         (lambda (symbol)
           (memq symbol '(+ - * / < = > <= >= abs exp log sin cos tan asin acos
                            atan sqrt expt zero? negative? positive? real)))))
    (define (all-arithmetic? expr)
      (cond ((pair? expr)
             (and (arithmetic? (car expr))
                  (every all-arithmetic? (cdr expr))))
            ((number? expr) #t)
            ((fol-var? expr) #t)
            (else #f)))
    (rule-simplifier
     (list
      tidy-empty-let
      (rule `(let ((?? bindings1)
                   ((? name ,fol-var?) (? exp ,all-arithmetic?))
                   (?? bindings2))
               (?? body))
            `(let (,@bindings1
                   ,@bindings2)
               ,@(replace-free-occurrences name exp body)))))))