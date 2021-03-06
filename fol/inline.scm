;;; ----------------------------------------------------------------------
;;; Copyright 2010-2011 National University of Ireland.
;;; ----------------------------------------------------------------------
;;; This file is part of DysVunctional Language.
;;; 
;;; DysVunctional Language is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU Affero General Public License as
;;; published by the Free Software Foundation, either version 3 of the
;;;  License, or (at your option) any later version.
;;; 
;;; DysVunctional Language is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;; 
;;; You should have received a copy of the GNU Affero General Public License
;;; along with DysVunctional Language.  If not, see <http://www.gnu.org/licenses/>.
;;; ----------------------------------------------------------------------

(declare (usual-integrations))
;;;; Inlining procedure definitions

;;; Inlining procedure definitions produces the following benefits:
;;; - Procedure boundaries are removed, giving later intraprocedural
;;;   optimizations more purchase.
;;; - Procedure bodies are cloned to their call sites, allowing
;;;   per-call-site specializations and optimizations.
;;; - Function call costs in the underlying implementation are
;;;   removed.

;;; Inlining procedure definitions also has the drawback of
;;; (potentially) increasing code size, causing:
;;; - Later stages to repeat work
;;; - Worse instruction cache performance in the final output

;;; This inliner makes the simplification that it will inline all or
;;; none of the call sites of any given procedure.  Given that, the
;;; question of selecting which procedures to inline can be reduced to
;;; a choice of vertices of the static call graph.  Since FOL is first
;;; order, the task of actually inlining the selected procedures
;;; becomes a search-and-replace of their names by their bodies.

(define (perform-inlining program names)
  (let ((lookup-defn (definition-map program))
        (walked-bodies (make-eq-hash-table)))
    ;; Memoize performing the inlining on a particular procedure's
    ;; body in an explicit hash table of promises to avoid repeating
    ;; it for every call site.
    (define (inline? name)
      (not (not (walked-body name))))
    (define (not-inline? form)
      (or (not (procedure-definition? form))
          (not (inline? (definiendum form)))))
    (define (walk expression)
      ((on-subexpressions
        (rule `((? name ,inline?) (?? args))
              (->let `(,(force (walked-body name)) ,@args))))
       expression))
    (define (walked-body name)
      (hash-table/get walked-bodies name #f))
    (for-each (lambda (name)
                (hash-table/put!
                 walked-bodies name
                 (delay (walk (definiens (remove-defn-argument-types
                                          (lookup-defn name)))))))
              names)
    (walk (filter not-inline? program))))

;;; So, which vertices of the call graph should be inlined?  The
;;; current strategy is to annotate the call graph with the
;;; multiplicity of its edges and with the per-call-site code size
;;; increase from inlining each procedure, and then greedily choose to
;;; inline the procedures that give the smallest overall increase
;;; until the proposed increase hits a threshold.

;;; This annotated call graph is represented as a list of records of
;;; the form
;;;   (procedure-name inline-cost . callee-names)
;;; where the list of callee names admits duplicates to indicate
;;; multiplicity.  The procedure CALL-GRAPH computes this graph for a
;;; given program.

(define (call-graph program)
  (define defined-name? (definition-map program))
  (define (make-record id cost out-neighbors)
    (cons id (cons cost out-neighbors)))
  (define (defn-inline-cost defn)
    (+ (count-pairs
        (definiens (remove-defn-argument-types defn)))
       ;; Let bindings, being a list of two-element lists, take a
       ;; little more space than an apply with an explicit lambda,
       ;; because that is two parallel lists.
       (length (cdr (cadr defn)))))
  (define (defn-vertex defn)
    (make-record
     (definiendum defn)
     (defn-inline-cost defn)
     (filter-tree defined-name? (definiens defn))))
  (define entry-point-vertex
    (let ((entry-point-name (make-name '%%main)))
      (make-record
       entry-point-name 0
       (cons entry-point-name ; Entry point is not inlinable
             (filter-tree defined-name? (entry-point program))))))
  (cons
   entry-point-vertex
   (map defn-vertex (filter procedure-definition? program))))

;;; The actual greedy graph algorithm is implemented by
;;; ACCEPTABLE-INLINEES in inlinees.scm.  So the toplevel inliner just
;;; picks a threshold and performs the inlining indicated by
;;; ACCEPTABLE-INLINEES on the call graph of the program.

(define (%inline program)
  (%%inline (count-pairs program) program))

(define (%%inline size-increase-threshold program)
  (tidy-begin
   (if (begin-form? program)
       (perform-inlining
        program
        (acceptable-inlinees
         size-increase-threshold (call-graph program)))
       program)))

;;; It is worth noting that with a threshold based on the current
;;; program size, this procedure is not idempotent.  Moreover, even if
;;; we were to target a fixed absolute size for the resulting program,
;;; compositions of this with CSE or dead code elimination would still
;;; not be idempotent, because those stages can shrink the size of a
;;; program and/or some of its constituent procedures (in the
;;; celestial mechanics example, by as much as 100x).

;;; Historical note: in the previous world order, the set of vertices
;;; not to inline was chosen as a feedback vertex set (set of vertices
;;; whose removal makes acyclic) of the static call graph, and the
;;; strategy was to inline everything else.  See
;;; feedback-vertex-set.scm for discussion and implementation.  This
;;; is mentioned because the feedback vertex set concept is a useful
;;; one to remember, and the code is still around.  Note that the
;;; implementation of the threshold approach contains a clause
;;; preventing the inlining of procedures that call themselves.

;;; The definition map is a facility for looking up the full
;;; definition form for a FOL procedure given its name.

(define (definition-map program)
  (define defn-map
    (alist->eq-hash-table
     (map (lambda (defn)
            (cons (definiendum defn) defn))
          (filter procedure-definition? program))))
  (lambda (name)
    (hash-table/get defn-map name #f)))

