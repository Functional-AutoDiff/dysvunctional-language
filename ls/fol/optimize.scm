(declare (usual-integrations))
;;;; Optimization toplevel

;;; The FOL optimizer consists of several stages:
;;; - ALPHA-RENAME
;;;   Uniquify local variable names.
;;; - INLINE
;;;   Inline non-recursive function definitions.
;;; - SCALAR-REPLACE-AGGREGATES
;;;   Replace aggregates with scalars.
;;; - INTRAPROCEDURAL-CSE
;;;   Eliminate common subexpressions (including redundant variables
;;;   that are just aliases of other variables or constants).
;;;   Perform some algebraic simplification during CSE.
;;; - ELIMINATE-INTRAPROCEDURAL-DEAD-VARIABLES
;;;   Eliminate dead code.
;;; - INTERPROCEDURAL-DEAD-VARIABLE-ELIMINATION
;;;   Eliminate dead code across procedure boundaries.
;;; - REVERSE-ANF
;;;   Inline bindings of variables that are only used once, to make
;;;   the output easier to read.

(define (fol-optimize program)
  ((lambda (x) x) ; This makes the last stage show up in the stack sampler
   (reverse-anf
    (interprocedural-dead-code-elimination
     (eliminate-intraprocedural-dead-variables
      (intraprocedural-cse
       (scalar-replace-aggregates
        (inline                         ; includes ALPHA-RENAME
         program))))))))

;;; The stages have the following structure and interrelationships:
;;;
;;; Almost all stages, with the notable exception of INLINE, depend
;;; on but also preserve uniqueness of variable names, so ALPHA-RENAME
;;; should be done first.  The definition of FOL-OPTIMIZE above bums
;;; this by noting that INLINE is called first anyway and relying on
;;; the ALPHA-RENAME inside it.
;;;
;;; Other than that, any stage is valid at any point, so the order and
;;; frequency of calling them is a question of their idempotence, what
;;; opportunities they expose for each other, and whether they give
;;; each other any excess work.  The following table summarizes these
;;; relationships.
#|
|          | Inline        | SRA         | CSE       | dead var  | un-anf |
|----------+---------------+-------------+-----------+-----------+--------|
| Inline   | almost idem   | no effect   | expose    | expose    | expose |
| SRA      | extra aliases | almost idem | expose    | expose    | fight  |
| CSE      | ~ expose      | no effect   | idem      | expose    | mixed  |
| dead var | ~ expose      | no effect   | no effect | idem      | expose |
| un-anf   | no effect     | form fight  | no effect | no effect | idem   |
|#
;;; Each cell in the table says what effect doing the stage on the
;;; left first has on subsequently doing the stage above.  "Expose"
;;; means that the stage on the left exposes opportunities for the
;;; stage above to be more effective.  "Idem" means the stage is
;;; idempotent, that is that repeating it twice in a row is no better
;;; than doing it once.  "~ expose" means it exposes opportunities in
;;; principle, but the current set of examples has not yet motivated
;;; me to try to take advantage of this.  I explain each cell
;;; individually below.

;;; Scalar replacement of aggregates pre-converts its input into
;;; approximate A-normal form, and does not attempt to undo this
;;; conversion.  This means other stages may have interesting
;;; commutators with SCALAR-REPLACE-AGGREGATES through their effect on
;;; ANF.
;;;
;;; Inline then Inline: Inlining is not idempotent in theory (see
;;; discussion in feedback-vertex-set.scm) but is idempotent on the
;;; extant examples.
;;;
;;; Inline then SRA: Inlining commutes with SRA up to removal of
;;; aliases (see explanation in SRA then Inline below).  I think
;;; inlining also makes SRA go faster because it reduces the number of
;;; procedure boundaries.
;;;
;;; Inline then others: Inlining exposes some interprocedural aliases,
;;; common subexpressions, dead code, and one-use variables to
;;; intraprocedural methods by collapsing some procedure boundaries.
;;; I do not know whether interprocedural-dead-code-elimination is
;;; good enough to get away without this aid in principle, but in
;;; practice inlining first greatly accelerates it.
;;;
;;; SRA then Inline: Inlining gives explicit names (former formal
;;; parameters) to the argument expressions of the procedure calls
;;; that are inlined, whether those expressions are compound or not.
;;; The ANF pre-filter of SRA synthesizes explicit names for any
;;; compound expression, including arguments of procedures that are up
;;; for inlining.  Therefore, doing SRA first creates extra names that
;;; just become aliases after inlining.  Up to removal of aliases,
;;; however, SRA and inlining commute.
;;;
;;; SRA then SRA: SRA is idempotent except in the case when the entry
;;; point returns a structured object (see sra.scm for why).  When
;;; support for union types is added, SRA will also become
;;; non-idempotent for the same reason that inlining is not
;;; idempotent.
;;; 
;;; SRA then others: SRA converts structure slots to variables,
;;; thereby exposing any aliases, common subexpressions, dead code, or
;;; instances of single use over those structure slots to the other
;;; stages, which focus exclusively on variables.
;;;
;;; CSE then inline: CSE may delete edges in the call graph by
;;; collapsing (* 0 (some-proc foo bar baz)) to 0 or by collapsing
;;; (if (some-proc foo) bar bar) into bar.
;;;
;;; CSE then SRA: CSE does not introduce SRA opportunities, though
;;; because it does algebraic simplifications it could in the
;;; non-union-free case.
;;;
;;; CSE then CSE: CSE is idempotent.
;;;
;;; CSE then eliminate: Formally, the job of common subexpression
;;; elimination is just to rename groups of references to some
;;; (possibly computed) object to refer to one representative variable
;;; holding that object, so that the bindings of the others can be
;;; cleaned up by dead variable elimination.  The particular CSE
;;; program implemented here opportunistically eliminates most of
;;; those dead bindings itself, but it does leave a few around to be
;;; cleaned up by dead variable elimination, in the case where some
;;; names bound by a multiple value binding form are dead but others
;;; are not.  CSE also exposes dead code opportunities by doing
;;; algebraic simplifications, including (* 0 foo) -> 0 and (if foo
;;; bar bar) -> bar.
;;;
;;; CSE then undo ANF: CSE does some of the work of reverse ANF by
;;; eliminating variables that are used only once and are also
;;; aliases.  By doing algebraic simplifications, CSE may also remove
;;; some uses of some variables, causing them to be inlinable.  On the
;;; other hand, CSE may increase the number of use sites of variables
;;; that are chosen as the canonical representatives of some computed
;;; expression, thereby preventing them from being inlined.
;;;
;;; Eliminate then inline: Dead variable elimination may delete edges
;;; in the call graph (if the result of a called procedure turned out
;;; not to be used); and may thus open inlining opportunities.
;;;
;;; Eliminate then SRA: Dead variable elimination does not create SRA
;;; opportunities (though it could in the non-union-free case if I
;;; eliminated dead structures or structure slots and were willing to
;;; change the type graph accordingly).
;;;
;;; Eliminate then CSE: Dead variable elimination does not expose
;;; common subexpressions.
;;;
;;; Eliminate then eliminate: Dead variable elimination is idempotent.
;;; The intraprocedural version is run first because it's faster and
;;; reduces the amount of work the interprocedural version would do
;;; while deciding what's dead and what isn't.
;;;
;;; Eliminate then undo ANF: Dead variable elimination reduces the
;;; number of use sites of variables that are used to compute things
;;; that are not needed, thus possibly making them singletons.
;;;
;;; Reverse-ANF then SRA: Reverse-ANF does not create SRA
;;; opportunities.  It does, however, undo some of the work of ANF
;;; conversion.  Consequently, SRA and REVERSE-ANF could fight
;;; indefinitely over the "normal form" of a program, each appearing
;;; to change it while neither doing anything useful.
;;;
;;; Reverse-ANF then reverse-ANF: Reverse-ANF is idempotent.
;;;
;;; Reverse-ANF then others: No effect.

;;; Watching the behavior of the optimizer

(define (optimize-visibly program)
  (report-size ; This makes the last stage show up in the stack sampler
   ((visible-stage reverse-anf)
    ((visible-stage interprocedural-dead-code-elimination)
     ((visible-stage eliminate-intraprocedural-dead-variables)
      ((visible-stage intraprocedural-cse)
       ((visible-stage scalar-replace-aggregates)
        ((visible-stage inline)             ; includes ALPHA-RENAME
         program))))))))
