(declare (usual-integrations))

(define (expression-dead-variable-elimination expr live-out)
  (define (ignore? name)
    (eq? name '_))
  (define (no-used-vars) '())
  (define (single-used-var var) (list var))
  (define (union vars1 vars2)
    (lset-union eq? vars1 vars2))
  (define (difference vars1 vars2)
    (lset-difference eq? vars1 vars2))
  (define used? memq)
  (define (loop expr live-out win)
    (cond ((symbol? expr)
           (win expr (single-used-var expr)))
          ((number? expr)
           (win expr (no-used-vars)))
          ((boolean? expr)
           (win expr (no-used-vars)))
          ((null? expr)
           (win expr (no-used-vars)))
          ((if-form? expr)
           (let ((predicate (cadr expr))
                 (consequent (caddr expr))
                 (alternate (cadddr expr)))
             (loop predicate #t
              (lambda (new-predicate pred-used)
                (loop consequent live-out
                 (lambda (new-consequent cons-used)
                   (loop alternate live-out
                    (lambda (new-alternate alt-used)
                      (win `(if ,new-predicate
                                ,new-consequent
                                ,new-alternate)
                           (union pred-used (union cons-used alt-used)))))))))))
          ((let-form? expr)
           (let ((bindings (cadr expr))
                 (body (caddr expr)))
             (loop body live-out
              (lambda (new-body body-used)
                (let ((new-bindings
                       (filter (lambda (binding)
                                 (used? (car binding) body-used))
                               bindings)))
                  (loop* (map cadr new-bindings)
                   (lambda (new-exprs exprs-used)
                     (let ((used (reduce union (no-used-vars) exprs-used)))
                       (win (empty-let-rule
                             `(let ,(map list (map car new-bindings)
                                         new-exprs)
                                ,new-body))
                            (union used (difference
                                         body-used (map car bindings))))))))))))
          ((let-values-form? expr)
           (let ((binding (caadr expr))
                 (body (caddr expr)))
             (let ((names (car binding))
                   (sub-expr (cadr binding)))
               (loop body live-out
                (lambda (new-body body-used)
                  (define (slot-used? name)
                    (or (ignore? name)
                        (and (used? name body-used)
                             #t)))
                  (let ((sub-expr-live-out (map slot-used? names)))
                    (if (any (lambda (x) x) sub-expr-live-out)
                        (loop sub-expr sub-expr-live-out
                         (lambda (new-sub-expr sub-expr-used)
                           (win (tidy-let-values
                                 `(let-values ((,(filter slot-used? names)
                                                ,new-sub-expr))
                                    ,new-body))
                                (union sub-expr-used
                                       (difference body-used names)))))
                        (win new-body body-used))))))))
          ;; If used post SRA, there may be constructions to build the
          ;; answer for the outside world, but there should be no
          ;; accesses.
          ((construction? expr)
           (loop* (cdr expr)
            (lambda (new-args args-used)
              (win `(,(car expr) ,@new-args)
                   (reduce union (no-used-vars) args-used)))))
          ((values-form? expr)
           (assert (list? live-out))
           (let ((wanted-elts (filter-map (lambda (wanted? elt)
                                            (and wanted? elt))
                                          live-out
                                          (cdr expr))))
             (loop* wanted-elts
              (lambda (new-elts elts-used)
                (win (if (= 1 (length new-elts))
                         (car new-elts)
                         `(values ,@new-elts))
                     (reduce union (no-used-vars) elts-used))))))
          (else ;; general application
           (loop* (cdr expr)
            (lambda (new-args args-used)
              (define (all-wanted? live-out)
                (or (equal? live-out #t)
                    (every (lambda (x) x) live-out)))
              (define (invent-name wanted?)
                (if wanted?
                    (make-name 'receipt)
                    '_))
              (let ((simple-new-call `(,(car expr) ,@new-args)))
                (let ((new-call
                       (if (all-wanted? live-out)
                           simple-new-call
                           (let ((receipt-names (map invent-name live-out)))
                             `(let-values ((,receipt-names ,simple-new-call))
                                (values ,@(filter (lambda (x) (not (ignore? x)))
                                                  receipt-names)))))))
                  (win new-call (reduce union (no-used-vars) args-used)))))))))
  (define (loop* exprs win)
    (if (null? exprs)
        (win '() '())
        (loop (car exprs) #t
         (lambda (new-expr expr-used)
           (loop* (cdr exprs)
            (lambda (new-exprs exprs-used)
              (win (cons new-expr new-exprs)
                   (cons expr-used exprs-used))))))))
  (loop expr live-out (lambda (new-expr used-vars) new-expr)))

(define (intraprocedural-dead-variable-elimination program)
  (if (begin-form? program)
      (append
       (map
        (rule `(define ((? name ,symbol?) (?? formals))
                 (argument-types (?? stuff) (? return))
                 (? body))
              `(define (,name ,@formals)
                 (argument-types ,@stuff ,return)
                 ,(expression-dead-variable-elimination
                   body (or (not (values-form? return))
                            (map (lambda (x) #t) (cdr return))))))
        (except-last-pair program))
       (list (expression-dead-variable-elimination
              (car (last-pair program)) #t)))
      (expression-dead-variable-elimination program #t)))

;;; To do interprocedural dead variable elimination I have to proceed
;;; as follows:
;;; -1) Run a round of intraprocedural dead variable elimination to
;;;     diminish the amount of work in the following (assume all
;;;     procedure calls need all their inputs)
;;; 0) Treat the final expression as a nullary procedure definition
;;; 1) Initialize a map for each procedure, mapping from output that
;;;    might be desired (by index) to input that is known to be needed
;;;    to compute that output.
;;;    - I know the answer for primitives
;;;    - All compound procedures start mapping every output to the empty
;;;      set of inputs known to be needed.
;;; 2) I can improve the map by walking the body of a procedure, carrying
;;;    down the set of desired outputs and bringing up the map saying
;;;    which outputs require which inputs
;;;    - Start with all outputs desired.
;;;    - A number requires no inputs for one output
;;;    - A variable requires itself for one output
;;;    - A VALUES maps its subexpressions to the desired outputs
;;;    - A LET is transparent on the way down, but if the variable it
;;;      is binding is desired as an input to its body, it recurs on
;;;      its expression desiring the one output.  Whatever input come
;;;      up need to be spliced in to the answers in the map coming from
;;;      the body.
;;;    - A LET-VALUES is analagous, but may choose to desire a subset
;;;      of its bound names.
;;;    - An IF recurs on the predicate desiring its output, and then
;;;      on the consequent and alternate passing the requests.  When
;;;      the answers come back, it needs to union the consequent and
;;;      alternate maps, and then add the predicate requirements as
;;;      inputs to all desired outputs of the IF.
;;;    - A procedure call refers to the currently known map for that
;;;      procedure.
;;;    - Whatever comes out of the top becomes the new map for this
;;;      procedure.
;;; 3) Repeat step 2 until no more improvements are possible.
;;; 4) Initialize a table of which inputs and outputs to each compound
;;;    procedure are actually needed.
;;;    - All procedures start not needed
;;;    - The entry point starts fully needed
;;; 5) I can improve this table by walking the body of a procedure
;;;    some of whose outputs are needed, carrying down the set of outputs
;;;    that are needed and bringing back up the set of inputs that are needed.
;;;    - At a procedure call, mark outputs of that procedure as needed in
;;;      the table if I found that I needed them on the walk; then take back
;;;      up the set of things that that procedure says it needs.
;;;    - Otherwise walk as in step 2 (check this!)
;;; 6) Repeat step 5 until no more improvements are possible.
;;; 7) Replace all definitions to
;;;    - Accept only those arguments they need (internally LET-bind all
;;;      others to tombstones)
;;;    - Return only those outputs that are needed (internally
;;;      LET-VALUES everything the body will generate, and VALUES out
;;;      that which is wanted)
;;; 8) Replace all call sites to
;;;    - Supply only those arguments that are needed (just drop
;;;      the rest)
;;;    - Solicit only those outputs that are needed (LET-VALUES them,
;;;      and VALUES what the body expects, filling in with tombstones).
;;; 9) Run a round of intraprocedural dead variable elimination to
;;;    clean up (all procedure calls now do need all their inputs)
;;;    - Verify that all the tombstones vanish.