;;; parseable.lisp --- software which may be parsed into ASTs

(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)

;;; parseable software objects
(define-software parseable (source)
  ((ast-root :initarg :ast-root :initform nil :accessor ast-root
             :documentation "Root node of AST.")
   (asts     :initarg :asts :reader asts
             :initform nil :copier :direct
             :type #+sbcl (list (cons keyword *) *) #-sbcl list
             :documentation
             "List of all ASTs.")
   (asts-changed-p :accessor asts-changed-p
                   :initform t :type boolean
                   :documentation
                   "Have ASTs changed since the last parse?")
   (copy-lock :initform (make-lock "parseable-copy")
              :copier :none
              :documentation "Lock while copying parseable objects."))
  (:documentation "Parsed AST tree software representation."))

(defgeneric roots (obj)
  (:documentation "Return all top-level ASTs in OBJ."))

(defgeneric asts (obj)
  (:documentation "Return a list of all asts in OBJ."))

(defgeneric get-ast (obj path)
  (:documentation "Return the AST in OBJ at PATH."))

(defgeneric get-parent-ast (obj ast)
  (:documentation "Return the parent node of AST in OBJ"))

(defgeneric get-parent-asts (obj ast)
  (:documentation "Return the parent nodes of AST in OBJ"))

(defgeneric get-immediate-children (obj ast)
  (:documentation "Return the immediate children of AST in OBJ."))

(defgeneric get-ast-types (software ast)
  (:documentation "Types directly referenced within AST."))

(defgeneric get-unbound-funs (software ast)
  (:documentation "Functions used (but not defined) within the AST."))

(defgeneric get-unbound-vals (software ast)
  (:documentation "Variables used (but not defined) within the AST."))

(defgeneric scopes (software ast)
  (:documentation "Return lists of variables in each enclosing scope.
Each variable is represented by an alist containing :NAME, :DECL, :TYPE,
and :SCOPE.
"))

(defgeneric get-vars-in-scope (software ast &optional keep-globals)
  (:documentation "Return all variables in enclosing scopes."))

(defgeneric update-asts (software)
  (:documentation "Update the store of asts associated with SOFTWARE."))

(defgeneric parse-asts (software)
  (:documentation "Parse genome of SOFTWARE, returning a list of ASTs."))

(defgeneric clear-caches (software)
  (:documentation "Clear cached fields on SOFTWARE"))

(defgeneric update-asts-if-necessary (software)
  (:documentation "Parse ASTs in SOFTWARE if the `ast-root' field
has not been set."))

(defgeneric update-caches-if-necessary (software)
  (:documentation "Update cached fields in SOFTWARE if these fields have
not been set."))

(defgeneric bad-asts (software)
  (:documentation "Return a list of all bad asts in SOFTWARE."))

(defgeneric good-asts (software)
  (:documentation "Return a list of all good asts in SOFTWARE."))

(defgeneric good-mutation-targets (software &key filter)
  (:documentation "Return a list of all good mutation targets in
SOFTWARE matching FILTER."))

(defgeneric bad-mutation-targets (software &key filter)
  (:documentation "Return a list of all bad mutation targets in
SOFTWARE matching FILTER."))

(defgeneric mutation-targets (software &key filter stmt-pool)
  (:documentation "Return a list of target ASTs in SOFTWARE from
STMT-POOL for mutation, filtering using FILTER, and throwing a
'no-mutation-targets exception if none are available."))

(defgeneric build-op (software mutation)
  (:documentation "Build operation on SOFTWARE from a MUTATION."))

(defgeneric recontextualize-mutation (parseable mutation)
  (:documentation "Bind free variables and functions in the mutation to concrete
values.  Additionally perform any updates to the software object required
for successful mutation."))

(defgeneric select-crossover-points (a b)
  (:documentation "Select suitable crossover points in A and B.
If no suitable points are found the returned points may be nil."))


;;; Core parseable methods
(defvar *parseable-obj-code* (register-code 45 'parseable)
  "Object code for serialization of parseable software objects.")

(defstore-cl-store (obj parseable stream)
  ;; NOTE: Does *not* support documentation.
  (let ((copy (copy obj)))
    (setf (slot-value copy 'copy-lock) nil)
    (output-type-code *parseable-obj-code* stream)
    (cl-store::store-type-object copy stream)))

(defrestore-cl-store (parseable stream)
  ;; NOTE: Does *not* support documentation.
  (let ((obj (cl-store::restore-type-object stream)))
    (setf (slot-value obj 'copy-lock) (make-lock "parseable-copy"))
    obj))

(defmethod copy :before ((obj parseable) &key)
  "Update ASTs in OBJ prior to performing a copy.
* OBJ software object to copy
"
  ;; Update ASTs before copying to avoid duplicates. Lock to prevent
  ;; multiple threads from updating concurrently.
  (unless (slot-value obj 'ast-root)
    (bordeaux-threads:with-lock-held ((slot-value obj 'copy-lock))
      (update-asts obj))))

(defmethod size ((obj parseable))
  "Return the number of ASTs in OBJ."
  (length (asts obj)))

(defmethod genome ((obj parseable))
  "Return the source code in OBJ."
  ;; If genome string is stored directly, use that. Otherwise,
  ;; build the genome by walking the AST.
  (if-let ((val (slot-value obj 'genome)))
    (progn (assert (null (slot-value obj 'ast-root)) (obj)
                   "Software object ~a has both genome and ASTs saved" obj)
           val)
    (peel-bananas (source-text (ast-root obj)))))

(defmethod (setf genome) :before (new (obj parseable))
  "Clear ASTs, fitness, and other caches prior to updating the NEW genome."
  (declare (ignorable new))
  (with-slots (ast-root fitness) obj
    (setf ast-root nil
          fitness nil))
  (clear-caches obj))

(defmethod (setf ast-root) :before (new (obj parseable))
  "Clear fitness and other caches prior to updating
the NEW ast-root."
  (declare (ignorable new))
  (with-slots (fitness) obj
    (setf fitness nil))
  (clear-caches obj))

(defmethod (setf ast-root) :after (new (obj parseable))
  "Ensure the AST paths in NEW are correct after modifying the
applicative AST tree."
  (setf (slot-value obj 'ast-root)
        (update-paths new)))

(defmethod update-paths
    ((tree ast) &optional path)
  "Return TREE with all paths updated to begin at PATH"
  (copy tree
        :path (reverse path)
        :children (iter (for c in (ast-children tree))
                        (for i upfrom 0)
                        (collect (if (subtypep (type-of c) 'ast)
                                     (update-paths c (cons i path))
                                     c)))))

(defmethod ast-root :before ((obj parseable))
  "Ensure the `ast-root' field is set on OBJ prior to access."
  (update-asts-if-necessary obj))

(defmethod size :before ((obj parseable))
  "Ensure the `asts' field is set on OBJ prior to access."
  (update-asts-if-necessary obj))

(defmethod asts :before ((obj parseable))
  "Ensure the `asts' field is set on OBJ prior to access."
  (update-caches-if-necessary obj))

(defmethod update-asts :around ((obj parseable))
  "Wrap update-asts to only parse OBJ when the `asts-changed-p'
field indicates the object has changed since the last parse."
  (when (asts-changed-p obj)
    (clear-caches obj)
    (call-next-method))
  (setf (asts-changed-p obj) nil))

(defmethod update-asts-if-necessary ((obj parseable))
  "Parse ASTs in obj if the `ast-root' field has not been set.
* OBJ object to potentially populate with ASTs
"
  (with-slots (ast-root) obj (unless ast-root (update-asts obj))))

(defmethod update-caches ((obj parseable))
  (labels ((collect-asts (tree)
             ;; Collect all subtrees
             (unless (null (ast-children tree))
               (cons tree
                     (iter (for c in (ast-children tree))
                           (unless (stringp c)
                             (appending (collect-asts c))))))))
    (setf (slot-value obj 'asts)
          (cdr (collect-asts (ast-root obj))))))

(defmethod update-caches-if-necessary ((obj parseable))
  "Update cached fields if these fields have not been set.
* OBJ object to potentially populate with cached fields
"
  (with-slots (asts) obj (unless asts (update-caches obj))))

(defmethod clear-caches ((obj parseable))
  "Clear cached fields on OBJ, including `asts' and `asts-changed-p`.
* OBJ object to clear caches for.
"
  (with-slots (asts asts-changed-p) obj
    (setf asts nil
          asts-changed-p t)))


;;; Retrieving ASTs
(defmethod roots ((obj parseable))
  "Return all top-level ASTs in OBJ.
* OBJ software object to search for roots
"
  (roots (asts obj)))

(defmethod roots ((asts list))
  "Return all top-level ASTs in ASTS.
* ASTS list of ASTs to search for roots
"
  (remove-if-not [{= 1} #'length #'ast-path] asts))

(defmethod ast-at-index ((obj parseable) index)
  "Return the AST in OBJ at INDEX.
* OBJ object to retrieve ASTs for
* INDEX nth AST to retrieve
"
  (nth index (asts obj)))

(defmethod index-of-ast ((obj parseable) (ast ast))
  "Return the index of AST in OBJ.
* OBJ object to query for the index of AST
* AST node to find the index of
"
  (position ast (asts obj) :test #'equalp))

(defmethod get-ast ((obj parseable) (path list))
  "Return the AST in OBJ at the given PATH.
* OBJ software object with ASTs
* PATH path to the AST to return
"
  (labels ((helper (tree path)
             (if path
                 (destructuring-bind (head . tail) path
                   (helper (nth head (ast-children tree))
                                tail))
                 tree)))
    (helper (ast-root obj) path)))

(defmethod parent-ast-p ((obj parseable) (possible-parent-ast ast) (ast ast))
  "Return true if POSSIBLE-PARENT-AST is a parent of AST in OBJ, nil
otherwise.
* OBJ software object containing AST and its parents
* POSSIBLE-PARENT-AST node to find as a parent of AST
* AST node to start parent search from
"
  (member possible-parent-ast (get-parent-asts obj ast)
          :test #'equalp))

(defmethod get-parent-ast ((obj parseable) (ast ast))
  "Return the parent node of AST in OBJ
* OBJ software object containing AST and its parent
* AST node to find the parent of
"
  (when-let ((path (butlast (ast-path ast))))
    (get-ast obj path)))

(defmethod get-parent-asts ((obj parseable) (ast ast))
  "Return the parent nodes of AST in OBJ
* OBJ software object containing AST and its parents
* AST node to find the parents of
"
  (labels ((get-parent-asts-helper (subtree path)
             (if (null path)
                 nil
                 (let ((new-subtree (nth (car path) (ast-children subtree))))
                   (cons new-subtree
                         (get-parent-asts-helper new-subtree
                                                 (cdr path)))))))
    (-> (get-parent-asts-helper (ast-root obj) (ast-path ast))
        (reverse))))

(defmethod get-immediate-children ((obj parseable) (ast ast))
  "Return the immediate children of AST in OBJ.
* OBJ software object containing AST and its children
* AST node to find the children of
"
  (declare (ignorable obj))
  (iter (for child in (ast-children ast))
        (when (subtypep (type-of child) 'ast)
          (collect child))))

(defmethod ast-to-source-range ((obj parseable) (ast ast))
  "Convert AST to pair of SOURCE-LOCATIONS."
  (labels
      ((scan-ast (ast line column)
         "Scan entire AST, updating line and column. Return the new values."
         (if (stringp ast)
             ;; String literal
             (iter (for char in-string ast)
                   (incf column)
                   (when (eq char #\newline)
                     (incf line)
                     (setf column 1)))

             ;; Subtree
             (iter (for child in (ast-children ast))
               (multiple-value-setq (line column)
                 (scan-ast child line column))))

         (values line column))
       (ast-start (ast path line column)
         "Scan to the start of an AST, returning line and column."
         (bind (((head . tail) path))
           ;; Scan preceeding ASTs
           (iter (for child in (subseq (ast-children ast) 0 head))
                 (multiple-value-setq (line column)
                   (scan-ast child line column)))
           ;; Recurse into child
           (when tail
             (multiple-value-setq (line column)
               (ast-start (nth head (ast-children ast)) tail line column)))
           (values line column))))

    (bind (((:values start-line start-col)
            (ast-start (ast-root obj) (ast-path ast) 1 1))
           ((:values end-line end-col)
            (scan-ast ast start-line start-col)))
      (make-instance 'source-range
                     :begin (make-instance 'source-location
                                           :line start-line
                                           :column start-col)
                     :end (make-instance 'source-location
                                         :line end-line
                                         :column end-col)))))

(defmethod ast-source-ranges ((obj parseable))
  "Return (AST . SOURCE-RANGE) for each AST in OBJ."
  (labels
      ((source-location (line column)
         (make-instance 'source-location :line line :column column))
       (scan-ast (ast line column)
         "Scan entire AST, updating line and column. Return the new values."
         (let* ((begin (source-location line column))
                (ranges
                 (if (stringp ast)
                     ;; String literal
                     (iter (for char in-string ast)
                           (incf column)
                           (when (eq char #\newline)
                             (incf line)
                             (setf column 1)))

                     ;; Subtree
                     (iter (for child in (ast-children ast))
                           (appending
                            (multiple-value-bind
                                  (ranges new-line new-column)
                                (scan-ast child line column)
                              (setf line new-line
                                    column new-column)
                              ranges)
                            into child-ranges)
                           (finally
                            (return
                              (cons (cons ast
                                          (make-instance 'source-range
                                                         :begin begin
                                                         :end (source-location
                                                               line column)))
                                    child-ranges)))))))

           (values ranges line column))))

    (cdr (scan-ast (ast-root obj) 1 1))))

(defmethod asts-containing-source-location
    ((obj parseable) (loc source-location))
  "Return a list of ASTs in OBJ containing LOC."
  (when loc
    (mapcar #'car
            (remove-if-not [{contains _ loc} #'cdr] (ast-source-ranges obj)))))

(defmethod asts-contained-in-source-range
    ((obj parseable) (range source-range))
  "Return a list of ASTs in contained in RANGE."
  (when range
    (mapcar #'car
            (remove-if-not [{contains range} #'cdr] (ast-source-ranges obj)))))

(defmethod asts-intersecting-source-range
    ((obj parseable) (range source-range))
  "Return a list of ASTs in OBJ intersecting RANGE."
  (when range
    (mapcar #'car
            (remove-if-not [{intersects range} #'cdr]
                           (ast-source-ranges obj)))))


;;; Genome manipulations
(defmethod prepend-to-genome ((obj parseable) text)
  "Prepend non-AST TEXT to OBJ genome.

* OBJ object to modify with text
* TEXT text to prepend to the genome
"
  (labels ((ensure-newline (text)
             (if (not (equalp #\Newline (last-elt text)))
                 (concatenate 'string text '(#\Newline))
                 text)))
    (with-slots (ast-root) obj
      (setf ast-root
            (copy ast-root
                  :children
                  (append (list (concatenate 'string
                                             (ensure-newline text)
                                             (car (ast-children ast-root))))
                          (cdr (ast-children ast-root))))))))

(defmethod append-to-genome ((obj parseable) text)
  "Append non-AST TEXT to OBJ genome.  The new text will not be parsed.

* OBJ object to modify with text
* TEXT text to append to the genome
"
  (with-slots (ast-root) obj
    (setf ast-root
          (copy ast-root
                :children
                (if (stringp (lastcar (ast-children ast-root)))
                    (append (butlast (ast-children ast-root))
                            (list (concatenate 'string
                                               (lastcar (ast-children ast-root))
                                               text)))
                    (append (ast-children ast-root) (list text)))))))


;; Targeting functions
(defmethod pick-bad ((obj parseable))
  "Pick a 'bad' index into a software object.
Used to target mutation."
  (if (bad-asts obj)
      (random-elt (bad-asts obj))
      (error (make-condition 'no-mutation-targets
               :obj obj :text "No asts to pick from"))))

(defmethod pick-good ((obj parseable))
  "Pick a 'good' index into a software object.
Used to target mutation."
  (if (good-asts obj)
      (random-elt (good-asts obj))
      (error (make-condition 'no-mutation-targets
               :obj obj :text "No asts to pick from"))))

(defmethod bad-asts ((obj parseable))
  "Return a list of all bad asts in OBJ"
  (asts obj))

(defmethod good-asts ((obj parseable))
  "Return a list of all good asts in OBJ"
  (asts obj))

(defmethod good-mutation-targets ((obj parseable) &key filter)
  "Return a list of all good mutation targets in OBJ matching FILTER.
* OBJ software object to query for good mutation targets
* FILTER predicate taking an AST parameter to allow for filtering
"
  (mutation-targets obj :filter filter :stmt-pool #'good-asts))

(defmethod bad-mutation-targets ((obj parseable) &key filter)
  "Return a list of all bad mutation targets in OBJ matching FILTER.
* OBJ software object to query for bad mutation targets
* FILTER predicate taking an AST parameter to allow for filtering
"
  (mutation-targets obj :filter filter :stmt-pool #'bad-asts))

(defmethod mutation-targets ((obj parseable)
                             &key (filter nil)
                                  (stmt-pool #'asts stmt-pool-supplied-p))
  "Return a list of target ASTs from STMT-POOL for mutation, throwing
a 'no-mutation-targets exception if none are available.

* OBJ software object to query for mutation targets
* FILTER filter AST from consideration when this function returns nil
* STMT-POOL method on OBJ returning a list of ASTs"
  (labels ((do-mutation-targets ()
             (if-let ((target-stmts
                        (if filter
                            (remove-if-not filter (funcall stmt-pool obj))
                            (funcall stmt-pool obj))))
               target-stmts
               (error (make-condition 'no-mutation-targets
                        :obj obj :text "No stmts match the given filter")))))
    (if (not stmt-pool-supplied-p)
        (do-mutation-targets)
        (restart-case
            (do-mutation-targets)
          (expand-stmt-pool ()
            :report "Expand statement pool of potential mutation targets"
            (mutation-targets obj :filter filter))))))

(defun pick-general (software first-pool &key second-pool filter)
  "Pick ASTs from FIRST-POOL and optionally SECOND-POOL, where FIRST-POOL and
SECOND-POOL are methods on SOFTWARE which return a list of ASTs.  An
optional filter function having the signature 'f ast &optional first-pick',
may be passed, returning true if the given AST should be included as a possible
pick or false (nil) otherwise."
  (let ((first-pick (some-> (mutation-targets software :filter filter
                                                   :stmt-pool first-pool)
                            (random-elt))))
    (if (null second-pool)
        (list (cons :stmt1 first-pick))
        (list (cons :stmt1 first-pick)
              (cons :stmt2 (some-> (mutation-targets software
                                                     :filter (lambda (ast)
                                                               (if filter
                                                                   (funcall filter ast first-pick)
                                                                   t))
                                                     :stmt-pool second-pool)
                                   (random-elt)))))))

(defmethod pick-bad-good ((software parseable) &key filter
                          (bad-pool #'bad-asts) (good-pool #'good-asts))
  "Pick two ASTs from SOFTWARE, first from `bad-pool' followed
by `good-pool', excluding those ASTs removed by FILTER.
* SOFTWARE object to perform picks for
* FILTER function taking two AST parameters and returning non-nil if the
second should be included as a possible pick
* BAD-POOL function returning a pool of 'bad' ASTs in SOFTWARE
* GOOD-POOL function returning a pool of 'good' ASTs in SOFTWARE
"
  (pick-general software bad-pool
                :second-pool good-pool
                :filter filter))

(defmethod pick-bad-bad ((software parseable) &key filter
                         (bad-pool #'bad-asts))
  "Pick two ASTs from SOFTWARE, both from the `bad-asts' pool,
excluding those ASTs removed by FILTER.
* SOFTWARE object to perform picks for
* FILTER function taking two AST parameters and returning non-nil if the
second should be included as a possible pick
* BAD-POOL function returning a pool of 'bad' ASTs in SOFTWARE
"
  (pick-general software bad-pool
                :second-pool bad-pool
                :filter filter))

(defmethod pick-bad-only ((software parseable) &key filter
                          (bad-pool #'bad-asts))
  "Pick a single AST from SOFTWARE from `bad-pool',
excluding those ASTs removed by FILTER.
* SOFTWARE object to perform picks for
* FILTER function taking two AST parameters and returning non-nil if the
second should be included as a possible pick
* BAD-POOL function returning a pool of 'bad' ASTs in SOFTWARE
"
  (pick-general software bad-pool :filter filter))


;;; Mutations
(defclass parseable-mutation (mutation)
  ()
  (:documentation "Specialization of the mutation interface for parseable
software objects."))

(define-mutation parseable-insert (parseable-mutation)
  ((targeter :initform #'pick-bad-good))
  (:documentation "Perform an insertion operation on a parseable software
object."))

(defmethod build-op ((mutation parseable-insert) software)
  "Return an association list with the operations to apply a `parseable-insert'
MUTATION to SOFTWARE.
* MUTATION defines targets of insertion operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software))
  `((:insert . ,(targets mutation))))

(define-mutation parseable-swap (parseable-mutation)
  ((targeter :initform #'pick-bad-bad))
  (:documentation "Perform a swap operation on a parseable software object."))

(defmethod build-op ((mutation parseable-swap) software)
  "Return an association list with the operations to apply a `parseable-swap'
MUTATION to SOFTWARE.
* MUTATION defines targets of the swap operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software))
  `((:set (:stmt1 . ,(aget :stmt1 (targets mutation)))
          (:stmt2 . ,(aget :stmt2 (targets mutation))))
    (:set (:stmt1 . ,(aget :stmt2 (targets mutation)))
          (:stmt2 . ,(aget :stmt1 (targets mutation))))))

;;; Move
(define-mutation parseable-move (parseable-mutation)
  ((targeter :initform #'pick-bad-bad))
  (:documentation "Perform a move operation on a parseable software object."))

(defmethod build-op ((mutation parseable-move) software)
  "Return an association list with the operations to apply a `parseable-move'
MUTATION to SOFTWARE.
* MUTATION defines targets of the move operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software))
  `((:insert (:stmt1 . ,(aget :stmt1 (targets mutation)))
             (:stmt2 . ,(aget :stmt2 (targets mutation))))
    (:cut (:stmt1 . ,(aget :stmt2 (targets mutation))))))

;;; Replace
(define-mutation parseable-replace (parseable-mutation)
  ((targeter :initform #'pick-bad-good))
  (:documentation "Perform a replace operation on a parseable
software object."))

(defmethod build-op ((mutation parseable-replace) software)
  "Return an association list with the operations to apply an
`parseable-replace' MUTATION to SOFTWARE.
* MUTATION defines targets of the replace operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software))
  `((:set . ,(targets mutation))))

(define-mutation parseable-cut (parseable-mutation)
  ((targeter :initform #'pick-bad-only))
  (:documentation "Perform a cut operation on a parseable software object."))

(defmethod build-op ((mutation parseable-cut) software)
  "Return an association list with the operations to apply a `parseable-cut'
MUTATION to SOFTWARE.
* MUTATION defines the targets of the cut operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software))
  `((:cut . ,(targets mutation))))

;;; Nop
(define-mutation parseable-nop (parseable-mutation)
  ()
  (:documentation "Perform a nop on a parseable software object."))

(defmethod build-op ((mutation parseable-nop) software)
  "Return an association list with the operations to apply a `nop'
MUTATION to SOFTWARE.
* MUATION defines teh targets of the nop operation
* SOFTWARE object to be modified by the mutation
"
  (declare (ignorable software mutation))
  nil)


;;; General mutation methods
(defmethod apply-mutation ((software parseable)
                           (mutation parseable-mutation))
  "Apply MUTATION to SOFTWARE, returning the resulting SOFTWARE.
* SOFTWARE object to be mutated
* MUTATION mutation to be performed
"
  (apply-mutation-ops software
                      ;; Sort operations latest-first so they
                      ;; won't step on each other.
                      (sort (recontextualize-mutation software mutation)
                            #'ast-later-p :key [{aget :stmt1} #'cdr])))

(defmethod apply-mutation ((obj parseable) (op list))
  "Apply OPS to SOFTWARE, returning the resulting SOFTWARE.
* OBJ object to be mutated
* OP mutation to be performed
"
  (apply-mutation obj (make-instance (car op) :targets (cdr op))))

(defmethod apply-mutation-ops ((software parseable) (ops list))
  "Apply a recontextualized list of OPS to SOFTWARE, returning the resulting
SOFTWARE.
* SOFTWARE object to be mutated
* OPS list of association lists with operations to be performed
"
  (setf (ast-root software)
        (with-slots (ast-root) software
          (iter (for (op . properties) in ops)
                (let ((stmt1 (aget :stmt1 properties))
                      (value1 (if (functionp (aget :value1 properties))
                                  (funcall (aget :value1 properties))
                                  (aget :value1 properties))))
                  (setf ast-root
                        (ecase op
                          (:set
                            (replace-ast ast-root stmt1 value1))
                          (:cut
                            (remove-ast ast-root stmt1))
                          (:insert
                            (insert-ast ast-root stmt1 value1))
                          (:insert-after
                            (insert-ast-after ast-root stmt1 value1))
                          (:splice
                            (splice-asts ast-root stmt1 value1)))))
                (finally (return ast-root)))))

  (clear-caches software)
  software)


;;; Generic tree interface
(defmethod insert-ast ((obj parseable) (location list) (ast ast))
  "Return the modified OBJ with AST inserted at LOCATION.
* OBJ object to be modified
* LOCATION path to the AST marking location where insertion is to occur
* AST AST to insert
"
  (insert-ast obj (get-ast obj location) ast))

(defmethod insert-ast ((obj parseable) (location ast) (ast ast))
  "Return the modified OBJ with AST inserted at LOCATION.
* OBJ object to be modified
* LOCATION AST marking location where insertion is to occur
* AST AST to insert
"
  (apply-mutation obj (at-targets (make-instance 'parseable-insert)
                                  (list (cons :stmt1 location)
                                        (cons :value1 ast)))))

(defmethod replace-ast ((obj parseable) (location list) (replacement ast))
  "Return the modified OBJ with the AST at LOCATION replaced with
REPLACEMENT.
* OBJ object to be modified
* LOCATION path to the AST to be replaced in OBJ
* REPLACEMENT Replacement AST
"
  (replace-ast obj (get-ast obj location) replacement))

(defmethod replace-ast ((obj parseable) (location ast) (replacement ast))
  "Return the modified OBJ with the AST at LOCATION replaced with
REPLACEMENT.
* OBJ object to be modified
* LOCATION AST to be replaced in OBJ
* REPLACEMENT Replacement AST
"
  (apply-mutation obj (at-targets (make-instance 'parseable-replace)
                                  (list (cons :stmt1 location)
                                        (cons :value1 replacement)))))

(defmethod remove-ast ((obj parseable) (location list))
  "Return the modified OBJ with the AST at LOCATION removed.
* OBJ object to be modified
* LOCATION path to the AST to be removed in TREE
"
  (remove-ast obj (get-ast obj location)))

(defmethod remove-ast ((obj parseable) (location ast))
  "Return the modified OBJ with the AST at LOCATION removed.
* OBJ object to be modified
* LOCATION AST to be removed in TREE
"
  (apply-mutation obj (at-targets (make-instance 'parseable-cut)
                                  (list (cons :stmt1 location)))))


;;; Customization for ast-diff.
(defmethod ast-diff ((parseable-a parseable) (parseable-b parseable))
  (ast-diff (ast-root parseable-a) (ast-root parseable-b)))

(defmethod ast-patch ((obj parseable) (diff list))
  (setf (ast-root obj) (ast-patch (ast-root obj) diff))
  obj)
