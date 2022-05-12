;;; javaimp-parse.el --- javaimp parsing  -*- lexical-binding: t; -*-

;; Copyright (C) 2021-2022  Free Software Foundation, Inc.

;; Author: Filipp Gunbin <fgunbin@fastmail.fm>
;; Maintainer: Filipp Gunbin <fgunbin@fastmail.fm>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(require 'cc-mode)                      ;for java-mode-syntax-table
(require 'cl-lib)
(require 'seq)

(cl-defstruct javaimp-scope
  type
  name
  start
  open-brace
  parent)


(defconst javaimp-scope-classlike-types
  '(class interface enum))

(defconst javaimp-scope-all-types
  (append
   '(anon-class
     array
     method
     simple-statement
     statement
     array)
   javaimp-scope-classlike-types))


(defconst javaimp-parse--classlike-keywords
  (mapcar #'symbol-name
          javaimp-scope-classlike-types))

(defconst javaimp-parse--stmt-keywords
  '("if" "else" "for" "while" "do" "switch" "try" "catch" "finally"
    "static"                            ; static initializer block
    ))
(defconst javaimp-parse--stmt-keyword-maxlen
  (seq-max (mapcar #'length javaimp-parse--stmt-keywords)))


(defun javaimp-parse--directive-regexp (directive)
  "Return regexp suitable for matching package-like DIRECTIVE, a
regexp.  First group is directive, second group is identifier."
  (rx bol (* space)
      (group (regexp directive)) (+ space)
      (group (+ (any alnum ?_)) (* ?. (+ (any alnum ?_ ?*))))
      (* space) ?\;))

(defconst javaimp-parse--package-regexp
  (javaimp-parse--directive-regexp "package"))
(defconst javaimp-parse--import-regexp
  (javaimp-parse--directive-regexp "import\\(?:[[:space:]]+static\\)?"))


(defvar javaimp-syntax-table
  (make-syntax-table java-mode-syntax-table) ;TODO don't depend on cc-mode
  "Javaimp syntax table")

(defvar javaimp--arglist-syntax-table
  (let ((st (make-syntax-table javaimp-syntax-table)))
    (modify-syntax-entry ?< "(>" st)
    (modify-syntax-entry ?> ")<" st)
    (modify-syntax-entry ?. "_" st) ; separates parts of fully-qualified type
    ;; Override prefix syntax so that scan-sexps right after @ in
    ;; annotation doesn't ignore it.
    (modify-syntax-entry ?@ "_" st)
    st)
  "Enables parsing angle brackets as lists")


(defvar-local javaimp-parse--dirty-pos nil
  "Marker which points to a buffer position after which all parsed
information should be considered as stale.  Usually set by
modification change hooks.  Nil value means we haven't yet parsed
anything in the buffer.  A marker pointing nowhere means
everything's up-to-date.")



;; Low-level subroutines

(defsubst javaimp-parse--substr-before-< (str)
  (let ((end (string-search "<" str)))
    (if end
        (string-trim (substring str 0 end))
      str)))

(defun javaimp-parse--rsb-keyword (regexp &optional bound noerror count)
  "Like `re-search-backward', but count only occurences which start
outside any syntactic context as given by `syntax-ppss-context'.
Assumes point is outside of any context initially."
  (or count (setq count 1))
  (let ((step (if (>= count 0) 1 -1))
        (case-fold-search nil)
        res)
    (dotimes (_ (abs count))
      (while (and (setq res (re-search-backward regexp bound noerror step))
                  (syntax-ppss-context (syntax-ppss)))))
    res))

(defun javaimp-parse--arglist (beg end &optional only-type)
  "Parse arg list between BEG and END, of the form 'TYPE NAME,
...'.  Return list of conses (TYPE . NAME).  If ONLY-TYPE is
non-nil, then name parsing is skipped."
  (let ((substr (buffer-substring-no-properties beg end)))
    (with-temp-buffer
      (insert substr)
      (with-syntax-table javaimp--arglist-syntax-table
        (ignore-errors
          (let (res)
            (while (progn
                     (javaimp-parse--skip-back-until)
                     (not (bobp)))
              (push (javaimp-parse--arglist-one-arg only-type) res)
              ;; move back to the previous argument, if any
              (when (javaimp-parse--skip-back-until
                     (lambda (_last-what _last-pos)
                       (and (not (bobp))
                            (= (char-before) ?,))))
                (backward-char)))       ; skip comma
            res))))))

(defun javaimp-parse--arglist-one-arg (only-type)
  "Parse one argument as type and name backwards starting from
point and return it in the form (TYPE . NAME).  Name is skipped
if ONLY-TYPE is non-nil.  Leave point at where the job is done:
skipping further backwards is done by the caller."
  (let ((limit (progn
                 (javaimp-parse--skip-back-until)
                 (point)))
        name)
    ;; Parse name
    (unless only-type
      (if (= 0 (skip-syntax-backward "w_"))
          (error "Cannot parse argument name")
        (setq name (buffer-substring-no-properties (point) limit))
        (javaimp-parse--skip-back-until)
        (setq limit (point))))
    ;; Parse type: allow anything, but stop at the word boundary which
    ;; is not inside list (this is presumably the type start..)
    (if-let ((last-skip
              (javaimp-parse--skip-back-until
               (lambda (_last-what last-pos)
                 (save-excursion
                   (if last-pos (goto-char last-pos))
                   (looking-at "\\_<"))))))
        (progn
          (unless (eq last-skip t)
            (goto-char (cdr last-skip))) ;undo skipping by ..-until
          (let ((type (replace-regexp-in-string
                       "[[:space:]\n]+" " "
                       (buffer-substring-no-properties (point) limit))))
            (cons type name)))
      (error "Cannot parse argument type"))))

(defun javaimp-parse--skip-back-until (&optional stop-p)
  "Goes backwards until position at which STOP-P returns non-nil, or reaching bob.

STOP-P is invoked with two arguments which describe the last
non-ws thing skipped: LAST-WHAT (symbol - either 'list' or
'char') and LAST-POS.  If STOP-P returns non-nil, then the return
value is also non-nil: either (LAST-WHAT . LAST-POS) if both are
non-nil or t.  Otherwise the return value is nil.

If STOP-P wants to look forward, it should be prepared to see
whitespace / comments, this is because backward movement skips
them before invoking STOP-P.  It should not move point.  If
omitted, it defaults to `always', in this case the effect of the
function is to just skip whitespace / comments."
  (or stop-p (setq stop-p #'always))
  (catch 'done
    (let (last-what last-pos)
      (while t
        (skip-syntax-backward " ")
        (let ((state (syntax-ppss)))
          (cond ((syntax-ppss-context state)
                 ;; move out of comment/string if in one
                 (goto-char (nth 8 state)))
                ((and (not (bobp))
                      (memql (syntax-class (syntax-after (1- (point))))
                             ;; comment end, generic comment
                             '(12 14)))
                 (backward-char))
                ((funcall stop-p last-what last-pos)
                 (throw 'done (if (and last-what last-pos)
                                  (cons last-what last-pos)
                                t)))
                ((bobp)
                 (throw 'done nil))
                ((= (syntax-class (syntax-after (1- (point)))) 5) ;close-paren
                 (backward-list)
                 (setq last-what 'list
                       last-pos (point)))
                (t
                 (backward-char)
                 (setq last-what 'char
                       last-pos (point)))))))))

(defun javaimp-parse--preceding (regexp scope-start &optional bound skip-count)
  "Returns non-nil if a match for REGEXP is found before point,
but not before BOUND.  Matches inside comments / strings are
skipped.  Potential match is checked to be SKIP-COUNT lists away
from the SCOPE-START (1 is for scope start itself, so if you want
to skip one additional list, use 2 etc.).  If a match is found,
then match-data is set, as for `re-search-backward'."
  (and (javaimp-parse--rsb-keyword regexp bound t)
       (ignore-errors
         ;; Does our match belong to the right block?
         (= (scan-lists (match-end 0) (or skip-count 1) -1)
            (1+ scope-start)))))

(defun javaimp-parse--decl-suffix (regexp brace-pos &optional bound)
  "Attempts to parse declaration suffix backwards from point (but
not farther than BOUND), returning non-nil on success.  More
precisely, the value is the end of the match for REGEXP.  Point
is left before the match.  Otherwise, the result is nil and point
is unchanged."
  (let ((pos (point)))
    (catch 'found
      (while (javaimp-parse--rsb-keyword regexp bound t)
        (let ((scan-pos (match-end 0)))
          (with-syntax-table javaimp--arglist-syntax-table
            ;; Skip over any number of lists, which may be exceptions
            ;; in "throws", or something like that
            (while (and scan-pos (<= scan-pos brace-pos))
              (if (ignore-errors
                    (= (scan-lists scan-pos 1 -1) ;As in javaimp-parse--preceding
                       (1+ brace-pos)))
                  (progn
                    (goto-char (match-beginning 0))
                    (throw 'found (match-end 0)))
                (setq scan-pos (ignore-errors
                                 (scan-lists scan-pos 1 0))))))))
      ;; just return to start
      (goto-char pos)
      nil)))

(defun javaimp-parse--decl-prefix (&optional bound)
  "Attempt to parse defun declaration prefix backwards from
point (but not farther than BOUND).  Matches inside comments /
strings are skipped.  Return the beginning of the match (then the
point is also at that position) or nil (then the point is left
unchanged)."
  ;; If we skip a previous scope (including unnamed initializers), or
  ;; reach enclosing scope start, we'll fail the check in the below
  ;; loop.  But a semicolon, which delimits statements, will just be
  ;; skipped by scan-sexps, so find it and use as bound.  If it is in
  ;; another scope, that's not a problem, for the same reasons as
  ;; described above.
  (let* ((prev-semi (save-excursion
                      (javaimp-parse--rsb-keyword ";" bound t)))
         (bound (when (or bound prev-semi)
                  (apply #'max
                         (delq nil
                               (list bound
                                     (and prev-semi (1+ prev-semi)))))))
         pos res)
    (with-syntax-table javaimp--arglist-syntax-table
      (while (and (ignore-errors
                    (setq pos (scan-sexps (point) -1)))
                  (or (not bound) (>= pos bound))
                  (or (member (char-after pos)
                              '(?@ ?\(  ;annotation type / args
                                   ?<)) ;generic type
                      ;; keyword / identifier first char
                      (= (syntax-class (syntax-after pos)) 2))) ;word
        (goto-char (setq res pos))))
    res))


;;; Scopes

(defun javaimp-scope-copy (scope)
  "Recursively copies SCOPE and its parents."
  (let* ((res (copy-javaimp-scope scope))
         (tmp res)
         orig-parent)
    (while (setq orig-parent (javaimp-scope-parent tmp))
      (setf (javaimp-scope-parent tmp) (copy-javaimp-scope orig-parent))
      (setq tmp (javaimp-scope-parent tmp)))
    res))

(defun javaimp-scope-filter-parents (scope pred)
  "Rewrite SCOPE's parents so that only those matching PRED are
left."
  (while scope
    (let ((parent (javaimp-scope-parent scope)))
      (if (and parent
               (not (funcall pred parent)))
          ;; leave out this parent
          (setf (javaimp-scope-parent scope) (javaimp-scope-parent parent))
        (setq scope (javaimp-scope-parent scope))))))

(defun javaimp-scope-concat-parents (scope)
  (let (parents)
    (while (setq scope (javaimp-scope-parent scope))
      (push scope parents))
    (mapconcat #'javaimp-scope-name parents ".")))

(defsubst javaimp-scope-test-type (scope leaf-types parent-types)
  (declare (indent 1))
  (let ((res (memq (javaimp-scope-type scope) leaf-types)))
    (while (and res
                (setq scope (javaimp-scope-parent scope)))
      (setq res (memq (javaimp-scope-type scope) parent-types)))
    res))

(defun javaimp-scope-defun-p (&optional additional)
  "Return predicate which matches scopes in
`javaimp-scope-classlike-types'.  ADDITIONAL is a list of scope
types.  If it includes `method', then also method leafs are
included.  If it includes `anon-class', then also leafs and
parents may be anonymous classes."
  (let ((leaf-types (append javaimp-scope-classlike-types
                            (when (memq 'method additional) '(method))
                            (when (memq 'anon-class additional) '(anon-class))))
        (parent-types (append javaimp-scope-classlike-types
                              (when (memq 'anon-class additional) '(anon-class)))))
    (lambda (s)
      (javaimp-scope-test-type s leaf-types parent-types))))

(defun javaimp-scope-same-parent-p (parent)
  (if parent
      (lambda (s)
        (and (javaimp-scope-parent s)
             (= (javaimp-scope-open-brace (javaimp-scope-parent s))
                (javaimp-scope-open-brace parent))))
    (lambda (s)
      (not (javaimp-scope-parent s)))))


;; Scope parsing

(defvar javaimp-parse--scope-hook
  (mapcar (lambda (parser)
            (lambda (arg)
              (save-excursion
                (funcall parser arg))))
          '(javaimp-parse--scope-array
            ;; anon-class should be before method/stmt because it
            ;; looks similar, but with "new" in front
            javaimp-parse--scope-anon-class
            javaimp-parse--scope-class
            javaimp-parse--scope-simple-stmt
            javaimp-parse--scope-method-or-stmt
            ))
  "List of parser functions, each of which is called in
`save-excursion' and with one argument, the position of opening
brace.")

(defun javaimp-parse--scope-class (brace-pos)
  "Attempts to parse 'class' / 'interface' / 'enum' scope."
  (when (javaimp-parse--preceding
         (regexp-opt javaimp-parse--classlike-keywords 'symbols)
         brace-pos
         ;; closest preceding closing paren is a good bound
         ;; because there _will be_ such char in frequent case
         ;; of method/stmt
         (save-excursion
           (when (javaimp-parse--rsb-keyword ")" nil t 1)
             (1+ (point)))))
    (let* ((keyword-start (match-beginning 1))
           (keyword-end (match-end 1))
           arglist)
      (goto-char brace-pos)
      (or (javaimp-parse--decl-suffix "\\_<extends\\_>" brace-pos keyword-end)
          (javaimp-parse--decl-suffix "\\_<implements\\_>" brace-pos keyword-end)
          (javaimp-parse--decl-suffix "\\_<permits\\_>" brace-pos keyword-end))
      ;; we either skipped back over the valid declaration
      ;; suffix(-es), or there wasn't any
      (setq arglist (javaimp-parse--arglist keyword-end (point) t))
      (when (= (length arglist) 1)
        (make-javaimp-scope :type (intern
                                   (buffer-substring-no-properties
                                    keyword-start keyword-end))
                            :name (javaimp-parse--substr-before-< (caar arglist))
                            :start keyword-start)))))

(defun javaimp-parse--scope-simple-stmt (_brace-pos)
  "Attempts to parse 'simple-statement' scope.  Currently block
lambdas are also recognized as such."
  (and (javaimp-parse--skip-back-until)
       (or (and (= (char-before (1- (point))) ?-) ; ->
                (= (char-before) ?>))
           (looking-back (regexp-opt javaimp-parse--stmt-keywords 'words)
                         (- (point) javaimp-parse--stmt-keyword-maxlen) nil))
       (make-javaimp-scope
        :type 'simple-statement
        :name (or (match-string 1)
                  "lambda")
        :start (or (match-beginning 1)
                   (- (point) 2)))))

(defun javaimp-parse--scope-anon-class (brace-pos)
  "Attempts to parse 'anon-class' scope."
  ;; skip arg-list and ws
  (when (and (progn
                 (javaimp-parse--skip-back-until)
                 (= (char-before) ?\)))
               (ignore-errors
                 (goto-char
                  (scan-lists (point) -1 0))))
      (let ((end (point))
            start arglist)
        (when (javaimp-parse--preceding "\\_<new\\_>" brace-pos nil 2)
          (setq start (match-beginning 0)
                arglist (javaimp-parse--arglist (match-end 0) end t))
          (when (= (length arglist) 1)
            (make-javaimp-scope :type 'anon-class
                                :name
                                (concat "<anon>"
                                        (javaimp-parse--substr-before-< (caar arglist)))
                                :start start))))))

(defun javaimp-parse--scope-method-or-stmt (brace-pos)
  "Attempts to parse 'method' or 'statement' scope."
  (let (;; take the closest preceding closing paren as the bound
        (throws-search-bound (save-excursion
                               (when (javaimp-parse--rsb-keyword ")" nil t 1)
                                 (1+ (point))))))
    (when throws-search-bound
      (let ((throws-args
             (when-let ((pos (javaimp-parse--decl-suffix
                              "\\_<throws\\_>" brace-pos throws-search-bound)))
               (or (javaimp-parse--arglist pos brace-pos t)
                   t))))
        (when (and (not (eq throws-args t))
                   (progn
                     (javaimp-parse--skip-back-until)
                     (= (char-before) ?\)))
                   (ignore-errors
                     ;; for method this is arglist
                     (goto-char
                      (scan-lists (point) -1 0))))
          (let* (;; leave open/close parens out
                 (arglist-region (cons (1+ (point))
                                       (1- (scan-lists (point) 1 0))))
                 (count (progn
                          (javaimp-parse--skip-back-until)
                          (skip-syntax-backward "w_")))
                 (name (and (< count 0)
                            (buffer-substring-no-properties
                             (point) (+ (point) (abs count)))))
                 (type (when name
                         (if (and (member name javaimp-parse--stmt-keywords)
                                  (not throws-args))
                             'statement 'method))))
            (when type
              (make-javaimp-scope
               :type type
               :name (if (eq type 'method)
                         (let ((args (javaimp-parse--arglist
                                      (car arglist-region)
                                      (cdr arglist-region))))
                           (concat name "(" (mapconcat #'car args ",") ")"))
                       name)
               :start (point)))))))))

(defun javaimp-parse--scope-array (_brace-pos)
  "Attempts to parse 'array' scope."
  (and (javaimp-parse--skip-back-until)
       (member (char-before) '(?, ?\]))
       (make-javaimp-scope :type 'array
                           :name ""
                           :start nil)))



(defun javaimp-parse--scopes (count)
  "Attempts to parse COUNT enclosing scopes at point.
Returns most nested one, with its parents sets accordingly.  If
COUNT is nil then goes all the way up.

Examines and sets property 'javaimp-parse-scope' at each scope's
open brace.  If neither of functions in
`javaimp-parse--scope-hook' return non-nil then the property
value is set to the symbol `unknown'.  Additionally, if a scope
is recognized, but any of its parents is 'unknown', then it's set
to 'unknown' too.

If point is inside of any comment/string then this function does
nothing."
  (let ((state (syntax-ppss))
        res)
    (unless (syntax-ppss-context state)
      (while (and (nth 1 state)
                  (or (not count)
                      (>= (setq count (1- count)) 0)))
        ;; find innermost enclosing open-bracket
        (goto-char (nth 1 state))
        (when (= (char-after) ?{)
          (let ((scope (get-text-property (point) 'javaimp-parse-scope)))
            (unless scope
              (setq scope (run-hook-with-args-until-success
                           'javaimp-parse--scope-hook (point)))
              (if scope
                  (setf (javaimp-scope-open-brace scope) (point))
                (setq scope 'unknown))
              (put-text-property (point) (1+ (point))
                                 'javaimp-parse-scope scope))
            (push scope res)
            (when (and (javaimp-scope-p scope)
                       (javaimp-scope-start scope))
              (goto-char (javaimp-scope-start scope)))))
        (setq state (syntax-ppss))))
    (let (parent reset-tail)
      (while res
        (if reset-tail
            ;; overwrite property value with `unknown'
            (when (javaimp-scope-p (car res))
              (let ((pos (javaimp-scope-open-brace (car res))))
                (put-text-property pos (1+ pos) 'javaimp-parse-scope 'unknown)))
          (if (javaimp-scope-p (car res))
              (progn
                (setf (javaimp-scope-parent (car res)) parent)
                (setq parent (car res)))
            ;; Just reset remaining scopes, and return nil
            (setq reset-tail t)
            (setq parent nil)))
        (setq res (cdr res)))
      parent)))

(defun javaimp-parse--all-scopes ()
  "Parses all scopes in this buffer which are after
`javaimp-parse--dirty-pos', if it points anywhere.  Makes it
point nowhere when done."
  (unless javaimp-parse--dirty-pos      ;init on first use
    (setq javaimp-parse--dirty-pos (point-min-marker))
    (javaimp-parse--setup-buffer))
  (when (marker-position javaimp-parse--dirty-pos)
    (with-silent-modifications          ;we update only private props
      (remove-text-properties javaimp-parse--dirty-pos (point-max)
                              '(javaimp-parse-scope nil))
      (goto-char (point-max))
      (let ((parse-sexp-ignore-comments t)
            ;; Can be removed when we no longer rely on cc-mode
            (parse-sexp-lookup-properties nil))
        (with-syntax-table javaimp-syntax-table
          (while (javaimp-parse--rsb-keyword "{" javaimp-parse--dirty-pos t)
            (save-excursion
              (forward-char)
              ;; Set props at this brace and all the way up
              (javaimp-parse--scopes nil))))))
    (set-marker javaimp-parse--dirty-pos nil)))

(defun javaimp-parse--setup-buffer ()
  ;; FIXME This may be done in major/minor mode setup
  (setq syntax-ppss-table javaimp-syntax-table)
  (setq-local multibyte-syntax-as-symbol t)
  (add-hook 'after-change-functions #'javaimp-parse--update-dirty-pos))

(defun javaimp-parse--enclosing-scope (&optional pred)
  "Return innermost enclosing scope matching PRED."
  (with-syntax-table javaimp-syntax-table
    (let ((state (syntax-ppss)))
      ;; Move out of any comment/string
      (when (nth 8 state)
	(goto-char (nth 8 state))
	(setq state (syntax-ppss)))
      (catch 'found
        (while t
          (let ((res (save-excursion
                       (javaimp-parse--scopes nil))))
            (when (and (javaimp-scope-p res)
                       (or (null pred)
                           (funcall pred res)))
              (throw 'found res))
            ;; Go up until we get something
            (if (nth 1 state)
                (progn
                  (goto-char (nth 1 state))
                  (setq state (syntax-ppss)))
              (throw 'found nil))))))))

(defun javaimp-parse--class-abstract-methods ()
  (goto-char (point-max))
  (let (res)
    (while (javaimp-parse--rsb-keyword "\\_<abstract\\_>" nil t)
      (save-excursion
        (let ((enclosing (nth 1 (syntax-ppss))))
          (when (and enclosing
                     (javaimp-parse--rsb-keyword ";" nil t -1)
                     ;; are we in the same nest?
                     (= (nth 1 (syntax-ppss)) enclosing))
            (backward-char)        ;skip semicolon
            ;; now parse as normal method scope
            (when-let ((scope (javaimp-parse--scope-method-or-stmt (point)))
                       ;; note that an abstract method with no
                       ;; parents will be ignored
                       (parent (javaimp-parse--scopes nil)))
              (setf (javaimp-scope-parent scope) (javaimp-scope-copy parent))
              (push scope res))))))
    res))

(defun javaimp-parse--interface-abstract-methods (int-scope)
  (let ((start (1+ (javaimp-scope-open-brace int-scope)))
        (end (ignore-errors
               (1- (scan-lists (javaimp-scope-open-brace int-scope) 1 0))))
        res)
    (when (and start end)
      (goto-char end)
      (while (and (> (point) start)
                  (javaimp-parse--rsb-keyword ";" start t))
        ;; are we in the same nest?
        (if (= (nth 1 (syntax-ppss)) (javaimp-scope-open-brace int-scope))
            (save-excursion
              ;; now parse as normal method scope
              (when-let ((scope (javaimp-parse--scope-method-or-stmt (point))))
                (setf (javaimp-scope-parent scope) int-scope)
                (push scope res)))
          ;; we've entered another nest, go back to its start
          (goto-char (nth 1 (syntax-ppss))))))
    res))

(defun javaimp-parse--update-dirty-pos (beg _end _old-len)
  "Function to add to `after-change-functions' hook."
  (when (and javaimp-parse--dirty-pos
             (or (not (marker-position javaimp-parse--dirty-pos))
                 (< beg javaimp-parse--dirty-pos)))
    (set-marker javaimp-parse--dirty-pos beg)))


;; Functions intended to be called from other parts of javaimp.  They
;; do not preserve excursion / restriction - it's the caller's
;; responsibility.

(defun javaimp-parse-get-package ()
  "Return the package declared in the current file.  Leaves point
at the end of directive."
  (javaimp-parse--all-scopes)
  (goto-char (point-max))
  (when (javaimp-parse--rsb-keyword javaimp-parse--package-regexp nil t 1)
    (goto-char (match-end 0))
    (match-string 2)))

(defun javaimp-parse-get-imports ()
  "Parse import directives in the current buffer and return (REGION
. CLASS-ALIST).  REGION, a cons of two positions, spans from bol
of first import to eol of last import.  CLASS-ALIST contains
elements (CLASS . TYPE), where CLASS is a string and TYPE is
either of symbols `normal' or 'static'."
  (javaimp-parse--all-scopes)
  (goto-char (point-max))
  (let (start-pos end-pos class-alist)
    (while (javaimp-parse--rsb-keyword javaimp-parse--import-regexp nil t)
      (setq start-pos (line-beginning-position))
      (unless end-pos
        (setq end-pos (line-end-position)))
      (push (cons (match-string 2)
                  (if (string-search "static" (match-string 1))
                      'static 'normal))
            class-alist))
    (cons (and start-pos end-pos (cons start-pos end-pos))
          class-alist)))

(defun javaimp-parse-get-all-scopes (&optional beg end pred parent-pred)
  "Return all scopes in the current buffer between positions BEG
and END, both exclusive, optionally filtering them with PRED, and
their parents with PARENT-PRED.  Neither of PRED or PARENT-PRED
should move point.  Note that parents may be outside of region
given by BEG and END.  BEG is the LIMIT argument to
`previous-single-property-change', and so may be nil.  END
defaults to end of accessible portion of the buffer."
  (javaimp-parse--all-scopes)
  (let ((pos (or end (point-max)))
        scope res)
    (while (and (setq pos (previous-single-property-change
                           pos 'javaimp-parse-scope nil beg))
                (or (not beg)
                    (/= pos beg)))
      (setq scope (get-text-property pos 'javaimp-parse-scope))
      (when (and (javaimp-scope-p scope)
                 (or (null pred)
                     (funcall pred scope)))
        (setq scope (javaimp-scope-copy scope))
        (when parent-pred
          (javaimp-scope-filter-parents scope parent-pred))
        (push scope res)))
    res))

(defun javaimp-parse-get-enclosing-scope (&optional pred parent-pred)
  "Return innermost enclosing scope at point, optionally checking
it with PRED, and its parents with PARENT-PRED."
  (save-excursion
    (javaimp-parse--all-scopes))
  (when-let ((scope (javaimp-parse--enclosing-scope pred)))
    (setq scope (javaimp-scope-copy scope))
    (when parent-pred
      (javaimp-scope-filter-parents scope parent-pred))
    scope))

(defun javaimp-parse-get-defun-decl-start (&optional bound)
  "Return the position of the start of defun declaration at point,
but not before BOUND.  Point should be at defun name, but
actually can be anywhere within the declaration, as long as it's
outside paren constructs like arg-list."
  (save-excursion
    (javaimp-parse--all-scopes))
  (javaimp-parse--decl-prefix bound))

(defun javaimp-parse-get-class-abstract-methods ()
  "Return all scopes which are abstract methods in classes."
  (javaimp-parse--all-scopes)
  (javaimp-parse--class-abstract-methods))

(defun javaimp-parse-get-interface-abstract-methods ()
  "Return all scopes which are abstract methods in interfaces."
  (let ((interfaces (javaimp-parse-get-all-scopes
                     nil nil
                     (lambda (s)
                       (javaimp-scope-test-type s
                         '(interface) javaimp-scope-classlike-types)))))
    (seq-mapcat #'javaimp-parse--interface-abstract-methods
                interfaces)))


(defun javaimp-parse-fully-parsed-p ()
  "Return non-nil if current buffer is fully parsed."
  (and javaimp-parse--dirty-pos
       (not (marker-position javaimp-parse--dirty-pos))))

(defmacro javaimp-parse-without-hook (&rest body)
  "Execute BODY, temporarily removing
`javaimp-parse--update-dirty-pos' from `after-change-functions'
hook."
  (declare (debug t) (indent 0))
  `(unwind-protect
       (progn
         (remove-hook 'after-change-functions #'javaimp-parse--update-dirty-pos)
         ,@body)
     (add-hook 'after-change-functions #'javaimp-parse--update-dirty-pos)))

(provide 'javaimp-parse)
