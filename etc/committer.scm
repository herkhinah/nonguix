#!/usr/bin/env -S guix repl
!#

;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2020, 2021 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2021 Sarah Morgensen <iskarian@mgsn.dev>
;;; Copyright © 2021 Xinglu Chen <public@yoctocell.xyz>
;;; Copyright © 2021 Jelle Licht <jlicht@fsfe.org>
;;;
;;; This file is not part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This script stages and commits changes to package definitions.

;;; Code:

(import (sxml xpath)
        (srfi srfi-1)
        (srfi srfi-2)
        (srfi srfi-9)
        (srfi srfi-11)
        (srfi srfi-26)
        (ice-9 format)
        (ice-9 popen)
        (ice-9 match)
        (ice-9 rdelim)
        (ice-9 regex)
        (ice-9 textual-ports)
        (guix gexp))

(define* (break-string str #:optional (max-line-length 70))
  "Break the string STR into lines that are no longer than MAX-LINE-LENGTH.
Return a single string."
  (define (restore-line words)
    (string-join (reverse words) " "))
  (if (<= (string-length str) max-line-length)
      str
      (let ((words+lengths (map (lambda (word)
                                  (cons word (string-length word)))
                                (string-tokenize str))))
        (match (fold (match-lambda*
                       (((word . length)
                         (count current lines))
                        (let ((new-count (+ count length 1)))
                          (if (< new-count max-line-length)
                              (list new-count
                                    (cons word current)
                                    lines)
                              (list length
                                    (list word)
                                    (cons (restore-line current) lines))))))
                     '(0 () ())
                     words+lengths)
          ((_ last-words lines)
           (string-join (reverse (cons (restore-line last-words) lines))
                        "\n"))))))

(define* (break-string-with-newlines str #:optional (max-line-length 70))
  "Break the lines of string STR into lines that are no longer than
MAX-LINE-LENGTH. Return a single string."
  (string-join (map (cut break-string <> max-line-length)
                    (string-split str #\newline))
               "\n"))

(define (read-excursion port)
  "Read an expression from PORT and reset the port position before returning
the expression."
  (let ((start (ftell port))
        (result (read port)))
    (seek port start SEEK_SET)
    result))

(define (surrounding-sexp port line-no)
  "Return the top-level S-expression surrounding the change at line number
LINE-NO in PORT."
  (let loop ((i (1- line-no))
             (last-top-level-sexp #f))
    (if (zero? i)
        last-top-level-sexp
        (match (peek-char port)
          (#\(
           (let ((sexp (read-excursion port)))
             (read-line port)
             (loop (1- i) sexp)))
          (_
           (read-line port)
           (loop (1- i) last-top-level-sexp))))))

(define-record-type <hunk>
  (make-hunk file-name
             old-line-number
             new-line-number
             diff-lines
             definition?)
  hunk?
  (file-name       hunk-file-name)
  ;; Line number before the change
  (old-line-number hunk-old-line-number)
  ;; Line number after the change
  (new-line-number hunk-new-line-number)
  ;; The full diff to be used with "git apply --cached"
  (diff-lines hunk-diff-lines)
  ;; Does this hunk add a definition?
  (definition? hunk-definition?))

(define* (hunk->patch hunk #:optional (port (current-output-port)))
  (let ((file-name (hunk-file-name hunk)))
    (format port
            "diff --git a/~a b/~a~%--- a/~a~%+++ b/~a~%~a"
            file-name file-name file-name file-name
            (string-join (hunk-diff-lines hunk) ""))))

(define (diff-info)
  "Read the diff and return a list of <hunk> values."
  (let ((port (open-pipe* OPEN_READ
                          "git" "diff-files"
                          "--no-prefix"
                          ;; Only include one context line to avoid lumping in
                          ;; new definitions with changes to existing
                          ;; definitions.
                          "--unified=1"
                          "guix/nongnu")))
    (define (extract-line-number line-tag)
      (abs (string->number
            (car (string-split line-tag #\,)))))
    (define (read-hunk)
      (let loop ((lines '())
                 (definition? #false))
        (let ((line (read-line port 'concat)))
          (cond
           ((eof-object? line)
            (values (reverse lines) definition?))
           ((or (string-prefix? "@@ " line)
                (string-prefix? "diff --git" line))
            (unget-string port line)
            (values (reverse lines) definition?))
           (else
            (loop (cons line lines)
                  (or definition?
                      (string-prefix? "+(define" line))))))))
    (define info
      (let loop ((acc '())
                 (file-name #f))
        (let ((line (read-line port)))
          (cond
           ((eof-object? line) acc)
           ((string-prefix? "--- " line)
            (match (string-split line #\space)
              ((_ file-name)
               (loop acc file-name))))
           ((string-prefix? "@@ " line)
            (match (string-split line #\space)
              ((_ old-start new-start . _)
               (let-values
                   (((diff-lines definition?) (read-hunk)))
                 (loop (cons (make-hunk file-name
                                        (extract-line-number old-start)
                                        (extract-line-number new-start)
                                        (cons (string-append line "\n")
                                              diff-lines)
                                        definition?) acc)
                       file-name)))))
           (else (loop acc file-name))))))
    (close-pipe port)
    info))

(define (lines-to-first-change hunk)
  "Return the number of diff lines until the first change."
  (1- (count (lambda (line)
               ((negate char-set-contains?)
                (char-set #\+ #\-)
                (string-ref line 0)))
             (hunk-diff-lines hunk))))

(define (old-sexp hunk)
  "Using the diff information in HUNK return the unmodified S-expression
corresponding to the top-level definition containing the staged changes."
  ;; TODO: We can't seek with a pipe port...
  (let* ((port (open-pipe* OPEN_READ
                           "git" "cat-file" "-p" (string-append
                                                  "HEAD:"
                                                  (hunk-file-name hunk))))
         (contents (get-string-all port)))
    (close-pipe port)
    (call-with-input-string contents
      (lambda (port)
        (surrounding-sexp port
                          (+ (lines-to-first-change hunk)
                             (hunk-old-line-number hunk)))))))

(define (new-sexp hunk)
  "Using the diff information in HUNK return the modified S-expression
corresponding to the top-level definition containing the staged changes."
  (call-with-input-file (hunk-file-name hunk)
    (lambda (port)
      (surrounding-sexp port
                        (+ (lines-to-first-change hunk)
                           (hunk-new-line-number hunk))))))

(define* (change-commit-message file-name old new #:optional (port (current-output-port)))
  "Print ChangeLog commit message for changes between OLD and NEW."
  (define (get-values expr field)
    (match ((sxpath `(// ,field quasiquote *)) expr)
      (() '())
      ((first . rest)
       (map cadadr first))))
  (define (listify items)
    (match items
      ((one) one)
      ((one two)
       (string-append one " and " two))
      ((one two . more)
       (string-append (string-join (drop-right items 1) ", ")
                      ", and " (first (take-right items 1))))))
  (define variable-name
    (second old))
  (define version
    (and=> ((sxpath '(// version *any*)) new)
           first))
  (format port
          "nongnu: ~a: Update to ~a.~%~%* ~a (~a): Update to ~a.~%"
          variable-name version file-name variable-name version)
  (for-each (lambda (field)
              (let ((old-values (get-values old field))
                    (new-values (get-values new field)))
                (or (equal? old-values new-values)
                    (let ((removed (lset-difference equal? old-values new-values))
                          (added (lset-difference equal? new-values old-values)))
                      (format port
                              "[~a]: ~a~%" field
                              (break-string
                               (match (list (map symbol->string removed)
                                            (map symbol->string added))
                                 ((() added)
                                  (format #f "Add ~a."
                                          (listify added)))
                                 ((removed ())
                                  (format #f "Remove ~a."
                                          (listify removed)))
                                 ((removed added)
                                  (format #f "Remove ~a; add ~a."
                                          (listify removed)
                                          (listify added))))))))))
            '(inputs propagated-inputs native-inputs)))

(define* (add-commit-message file-name variable-name #:optional (port (current-output-port)))
  "Print ChangeLog commit message for a change to FILE-NAME adding a definition."
  (format port
          "nongnu: Add ~a.~%~%* ~a (~a): New variable.~%"
          variable-name file-name variable-name))

(define* (custom-commit-message file-name variable-name message changelog
                                #:optional (port (current-output-port)))
  "Print custom commit message for a change to VARIABLE-NAME in FILE-NAME, using
MESSAGE as the commit message and CHANGELOG as the body of the ChangeLog
entry. If CHANGELOG is #f, the commit message is reused. If CHANGELOG already
contains ': ', no colon is inserted between the location and body of the
ChangeLog entry."
  (define (trim msg)
    (string-trim-right (string-trim-both msg) (char-set #\.)))

  (define (changelog-has-location? changelog)
    (->bool (string-match "^[[:graph:]]+:[[:blank:]]" changelog)))

  (let* ((message (trim message))
         (changelog (if changelog (trim changelog) message))
         (message/f (format #f "nongnu: ~a: ~a." variable-name message))
         (changelog/f (if (changelog-has-location? changelog)
                          (format #f "* ~a (~a)~a."
                                  file-name variable-name changelog)
                          (format #f "* ~a (~a): ~a."
                                  file-name variable-name changelog))))
    (format port
            "~a~%~%~a~%"
            (break-string-with-newlines message/f 72)
            (break-string-with-newlines changelog/f 72))))

(define (add-copyright-line line)
  "Add the copyright line on LINE to the previous commit."
  (let ((author (match:substring
                 (string-match "^\\+;;; Copyright ©[^[:alpha:]]+(.*)$" line)
                 1)))
    (format
     (current-output-port) "Amend and add copyright line for ~a~%" author)
    (system* "git" "commit" "--amend" "--no-edit")))

(define (group-hunks-by-sexp hunks)
  "Return a list of pairs associating all hunks with the S-expression they are
modifying."
  (fold (lambda (sexp hunk acc)
          (match acc
            (((previous-sexp . hunks) . rest)
             (if (equal? sexp previous-sexp)
                 (cons (cons previous-sexp
                             (cons hunk hunks))
                       rest)
                 (cons (cons sexp (list hunk))
                       acc)))
            (_
             (cons (cons sexp (list hunk))
                   acc))))
        '()
        (map new-sexp hunks)
        hunks))

(define (new+old+hunks hunks)
  (map (match-lambda
         ((new . hunks)
          (cons* new (old-sexp (first hunks)) hunks)))
       (group-hunks-by-sexp hunks)))

(define %delay 1000)

(define (main . args)
  (define* (change-commit-message* file-name old new #:rest rest)
    (let ((changelog #f))
      (match args
        ((or (message changelog) (message))
         (apply custom-commit-message
                file-name (second old) message changelog rest))
        (_
         (apply change-commit-message file-name old new rest)))))

  (match (diff-info)
    (()
     (display "Nothing to be done.\n" (current-error-port)))
    (hunks
     (let-values
         (((definitions changes)
           (partition hunk-definition? hunks)))

       ;; Additions.
       (for-each (lambda (hunk)
                   (and-let*
                       ((define-line (find (cut string-prefix? "+(define" <>)
                                           (hunk-diff-lines hunk)))
                        (variable-name (and=> (string-tokenize define-line) second)))
                     (add-commit-message (hunk-file-name hunk) variable-name)
                     (let ((port (open-pipe* OPEN_WRITE
                                             "git" "apply"
                                             "--cached"
                                             "--unidiff-zero")))
                       (hunk->patch hunk port)
                       (unless (eqv? 0 (status:exit-val (close-pipe port)))
                         (error "Cannot apply")))

                     (let ((port (open-pipe* OPEN_WRITE "git" "commit" "-F" "-")))
                       (add-commit-message (hunk-file-name hunk)
                                           variable-name port)
                       (usleep %delay)
                       (unless (eqv? 0 (status:exit-val (close-pipe port)))
                         (error "Cannot commit"))))
                   (usleep %delay))
                 definitions)

       ;; Changes.
       (for-each (match-lambda
                   ((new old . hunks)
                    (for-each (lambda (hunk)
                                (let ((port (open-pipe* OPEN_WRITE
                                                        "git" "apply"
                                                        "--cached"
                                                        "--unidiff-zero")))
                                  (hunk->patch hunk port)
                                  (unless (eqv? 0 (status:exit-val (close-pipe port)))
                                    (error "Cannot apply")))
                                (usleep %delay))
                              hunks)
                    (define copyright-line
                      (any (lambda (line) (and=> (string-prefix? "+;;; Copyright ©" line)
                                              (const line)))
                                (hunk-diff-lines (first hunks))))
                    (cond
                     (copyright-line
                      (add-copyright-line copyright-line))
                     (else
                      (let ((port (open-pipe* OPEN_WRITE "git" "commit" "-F" "-")))
                        (change-commit-message* (hunk-file-name (first hunks))
                                                old new)
                      (change-commit-message* (hunk-file-name (first hunks))
                                              old new
                                              port)
                      (usleep %delay)
                      (unless (eqv? 0 (status:exit-val (close-pipe port)))
                        (error "Cannot commit")))))))
                 ;; XXX: we recompute the hunks here because previous
                 ;; insertions lead to offsets.
                 (new+old+hunks (diff-info)))))))

(apply main (cdr (command-line)))
