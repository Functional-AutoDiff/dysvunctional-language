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
;;;; Scheme names for generated code pieces

;;; Nothing to see here.

(define (vl-variable->scheme-variable var) var)

(define (vl-variable->scheme-field-name var) var)

(define (vl-variable->scheme-record-access var closure)
  `(,(symbol (abstract-closure->scheme-structure-name closure)
             '- (vl-variable->scheme-field-name var))
    the-closure))

(define (fresh-temporary)
  (make-name 'temp))

(define *closure-names* (make-abstract-hash-table))

(define (abstract-closure->scheme-structure-name closure)
  (hash-table/intern! *closure-names* closure
   (lambda () (name->symbol (make-name 'closure)))))

(define (abstract-closure->scheme-constructor-name closure)
  (symbol 'make- (abstract-closure->scheme-structure-name closure)))

(define *call-site-names* (make-abstract-hash-table))

(define (call-site->scheme-function-name closure abstract-arg)
  (hash-table/intern! *call-site-names* (cons closure abstract-arg)
   (lambda () (name->symbol (make-name 'operation)))))

(define *escaper-names* (make-abstract-hash-table))

(define (escaping-closure->scheme-function-name closure)
  (hash-table/intern! *escaper-names* closure
   (lambda () (name->symbol (make-name 'escaping-operation)))))

(define *escaper-type-names* (make-abstract-hash-table))

(define (escaping-closure->scheme-type-name closure)
  (hash-table/intern! *escaper-type-names* closure
   (lambda () (name->symbol (make-name 'escaper-type)))))

(define (clear-name-caches!)
  (set! *closure-names* (make-abstract-hash-table))
  (set! *call-site-names* (make-abstract-hash-table))
  (set! *escaper-names* (make-abstract-hash-table))
  (set! *escaper-type-names* (make-abstract-hash-table)))

(define (initialize-name-caches!)
  (set! *closure-names* (make-abstract-hash-table))
  (set! *call-site-names* (make-abstract-hash-table))
  (set! *escaper-names* (make-abstract-hash-table))
  (set! *escaper-type-names* (make-abstract-hash-table))
  (reset-fol-names!))
