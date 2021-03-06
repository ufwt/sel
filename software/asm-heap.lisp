;;; asm-heap.lisp --- parse assembly code into asm-line-info structs
(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)

(defstruct (asm-line-info (:copier copy-asm-line-info))
  text    ;; original text
  tokens  ;; list of tokens after parsing
  type    ;; empty (white space/comments), decl, data, label-decl, op)
  label   ;; for operations which refer to labels
  opcode  ;; for operations
  operands;; the operands that are associated with the opcode
  id      ;; unique index in heap, sequential starting at 0
  orig-file ;; path of the orignal .asm file that was loaded (if any)
  orig-line ;; line number (0-based) of line in original .asm file (if any)
  address ;; original address of code or data
  )

;;; This read-table and package are used for parsing ASM instructions.
(defvar *assembler-x86-readtable* (copy-readtable))
(defpackage :software-evolution-library/asm (:nicknames :sel/asm))

;;
;; treat some characters such as : and , as special tokens
;;
(set-macro-character #\: (lambda (stream ch)(declare (ignore stream ch)) :colon)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\, (lambda (stream ch)(declare (ignore stream ch)) :comma)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\[ (lambda (stream ch)
			   (declare (ignore stream ch))
			   :\[)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\] (lambda (stream ch)
			   (declare (ignore stream ch))
			   :\])
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\+ (lambda (stream ch)
			   (declare (ignore stream ch))
			   :+)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\* (lambda (stream ch)
			   (declare (ignore stream ch))
			   :*)
		     nil
		     *assembler-x86-readtable*)

;; If we encounter a single quote, look for the terminating quote.
(set-macro-character
 #\'
 (lambda (stream ch)
   (declare (ignore ch))
   (let ((chars nil)(eof (cons nil nil)))
     (flet ((get-char ()
              (let ((ch (read-char stream nil eof t)))
                (when (eq ch eof)
                  (error "Unterminated single-quoted string found"))
                ch)))
       (do ((ch (get-char) (get-char))
            (count 0 (1+ count)))
           ((char= ch #\')
            (make-array count
                        :element-type 'character
                        :initial-contents (nreverse chars)))
         ;; handle '\' as an escape character
         (push (if (char= ch #\\)(get-char) ch) chars)))))

 nil
 *assembler-x86-readtable*)

(defun tokenize-asm-line (line)
  "Take a line of text from a .asm file, and, and converts it to tokens."
  (with-input-from-string (s line)
    (do* ((*readtable* *assembler-x86-readtable*)
	  (*package* (find-package :sel/asm))
	  (result '())
	  (eof (cons 0 0))
	  (token (read s nil eof)(read s nil eof)))
	 ((eq token eof)(nreverse result))
	(push token result))))

(defun token-labelp (token)
  (and (symbolp token)
       (char= (char (symbol-name token) 0) #\$)))

;;; Given a list of tokens representing the line, returns either of:
;;;     :nothing
;;;     :declaration
;;;     :data
;;;     :label
;;;     :operation
(defun parse-line-type (tokens)
  (cond ((null tokens) ':empty)
	((and (token-labelp (first tokens)) ; first token symbol beg. with '$'?
	      (eq (second tokens) :colon))  ; followed by a ':'?
	 ':label-decl)
	((or (member 'sel/asm::db tokens)
	     (member 'sel/asm::dq tokens)
	     (member 'sel/asm::dd tokens)
	     (member 'sel/asm::dw tokens))
	 ':data)
	((member (first tokens)
                 '(sel/asm::align
                   sel/asm::section
                   sel/asm::extern
                   sel/asm::%define
                   sel/asm::global))
	 ':decl)
	((and (token-labelp (first tokens))
	      (eq (second tokens) 'sel/asm::equ))
	 ':decl)
	(t ':op)))     ;; use this as catch-all for anything else

;;;
;;; takes a line of text from a .asm file, and, and returns 1 or 2
;;; asm-line-info structs.  If the line begins with a label, the line
;;; is split into two lines: the label, and the remaining
;;; text/tokens. In this case 2 asm-line-info structs are returned.
;;; Otherwise, as single asm-line-info is returned.
;;;
(defun parse-asm-line (line)
  (let* ((tokens (tokenize-asm-line line))
	 (info (make-asm-line-info :text line :tokens tokens)))

    ;; see if there is a comment: "orig ea=0xnnnnnnnn" which specifies
    ;; the original address of code or data
    (let* ((addr-comment "orig ea=0x")
	   (addr-pos (search addr-comment line :from-end t :test 'equal)))
      (if addr-pos
	  (setf (asm-line-info-address info)
		(parse-integer line
			       :radix 16
			       :start (+ (length addr-comment) addr-pos)
			       :junk-allowed t))))
    
    ;; Determine type of line
    (let ((line-type (parse-line-type tokens)))
      (setf (asm-line-info-type info) line-type)

      (case line-type
	(:label-decl (let* ((label (first tokens))
                            (label-end (position #\: line))
                            (line1 (subseq line 0 (+ label-end 1)))
                            (line2 (subseq line (+ label-end 1)))
                            (next-info (parse-asm-line line2))) ;; recurse!
                       (setf (asm-line-info-text info) line1)
                       (setf (asm-line-info-tokens info) (list label ':colon))
                       (setf (asm-line-info-label info) label)
                       (if (and next-info (not (eq (asm-line-info-type
                                                    (car next-info))
                                                   ':empty)))
                           ;; If an empty line follows the label, discard it.
                           (cons info next-info)
                           (progn
                             ; Restore full text line.
                             (setf (asm-line-info-text info) line)
                             (list info)))))
	(:empty (list info))
	(:op (setf (asm-line-info-opcode info) (first tokens))
	     (let ((comma-pos (position ':comma (rest tokens))))
	       (setf (asm-line-info-operands info)
		     (if comma-pos
			 (list
			  (subseq (rest tokens) 0 comma-pos)
			  (subseq (rest tokens) (+ comma-pos 1)))
			 (list (rest tokens)))))
	     (list info))
	(:data (list info))
	(:decl (list info))))))

;;;
;;; Convert an operand (from ASM-LINE-INFO-OPERANDS list) to text string.
;;;
(defun format-asm-operand (op) ; list of tokens
  (format nil "~{~A~}"
	  (mapcar (lambda (x)
		 (if (member x '(sel/asm::qword
				 sel/asm::dword
				 sel/asm::word
				 sel/asm::byte))
		     (format nil "~A " x)
		     x))
		  op)))

(defun update-asm-line-info-text (asm-line)
  "Update the TEXT field of ASM-LINE-INFO after updated operation or operands."
  (when (eq (asm-line-info-type asm-line) ':op)
    (setf (asm-line-info-text asm-line)
	(format nil "~A ~{~A~^, ~}"
		(asm-line-info-opcode asm-line)
		(mapcar 'format-asm-operand
			(asm-line-info-operands asm-line))))))


;;; asm-heap software objects
;;
;; An software object which uses less memory. even less memory, but
;; adds some complexity to many genome manipulation methods.  The
;; line-heap holds the original lines of the program (before any
;; mutations, along with any new or modified lines appended to the end
;; of the heap. All elements of the genome are references into this
;; line-heap.  history is a list of asm-edit structs, representing the
;; edit history. The first item in the list is the newest edit.
;;
;;
(define-software asm-heap (asm)
  ((line-heap :initarg :line-heap :accessor line-heap))
  (:documentation
   "Alternative to SIMPLE software objects which should use less memory.
Similar to RANGE, but allows for adding and mutating lines, and should
be able to handle type of mutation we need. The GENOME is a vector of
references into the asm-heap (asm-line-info) describes the code."))

(defmethod size ((asm asm-heap))
  "Return the number of lines in the program."
  (length (genome asm)))

(defun line-heap-copy (heap)
  (let ((new (make-array (length heap) :fill-pointer (length heap)
			 :adjustable t :initial-contents heap)))
    new))

(defmethod lines ((asm asm-heap))
  "Return the list of text lines of the genome."
  (map 'list 'asm-line-info-text (genome asm)))

(defmethod (setf lines) (asm-lines (asm asm-heap))
  "Initializes the line-heap.
Does this by converting the passed list of lines to ASM-LINE-INFO
structs, and storing them in a vector on the LINE-HEAP"
  (let* ((asm-infos '())
	 (orig-line 0)
	 (id 0))
    (dolist (line asm-lines)
      (dolist (asm-info (parse-asm-line line))
	(setf (asm-line-info-id asm-info) id)
	(setf (asm-line-info-orig-line asm-info) orig-line)
	(incf id)
	(push asm-info asm-infos))
      (incf orig-line))
    (setf asm-infos (nreverse asm-infos))
    (let* ((size (length asm-infos))
	   (heap (make-array size
                             :fill-pointer size :adjustable t
                             :initial-contents asm-infos)))
      (setf (line-heap asm) heap)
      ;; Make a copy for this instance.
      (setf (genome asm)(line-heap-copy heap)))))

(defmethod from-file ((asm asm-heap) file)
  "Initialize an `asm-heap' software object from a file."
  (setf (lines asm) (split-sequence #\Newline (file-to-string file)))
  ;; tag all the heap entries with the original file name
  (map nil (lambda (info) (setf (asm-line-info-orig-file info) file))
       (line-heap asm))
  asm)

(defmethod to-file ((asm asm-heap) file)
  "Save the assembly for ASM to FILE."
  (with-open-file (out file :direction :output :if-exists :supersede)
    (genome-string asm out)))

(defun vector-cut (a index)
  "Destructively remove and return an element from a vector with a fill pointer."
  (let ((deleted (aref a index)))
    (do ((i index (+ i 1)))
	((= i (- (length a) 1))(decf (fill-pointer a)))
      (setf (aref a i)(aref a (+ i 1))))
    deleted))

(defun vector-insert (a index val)
  "Destructively insert and return an object into a vector with a fill pointer."
  (vector-push-extend 0 a) ; Increase size by 1 (will be resized if necessary).
  (do ((i (- (length a) 1) (- i 1)))
      ((= i index)(setf (aref a i) val))
    (setf (aref a i)(aref a (- i 1)))))

;;;
;;; Given a textual line of assembler, parse it and add the resulting
;;; list of asm-line-info structs to the heap.
;;; Returns the list of new asm-line-info struct.
;;;
(defun parse-and-add-to-heap (asm-heap text)
  (let* ((info-list (parse-asm-line text))
	 (id (length (line-heap asm-heap))))
    (dolist (info info-list)
      (setf (asm-line-info-id info) id)
      (incf id)
      (vector-push-extend info (line-heap asm-heap)))
    info-list))

;;;
;;; Parses a new line of assembler, adds it to the heap, and inserts
;;; it at index in the genome. Returns the number of lines inserted.
;;;
(defun insert-new-line (asm-heap text index)
  (let ((info-list (parse-and-add-to-heap asm-heap text)))
    (dolist (info info-list)
      (vector-insert (genome asm-heap) index info)
      (incf index))
    (length info-list)))

;;;
;;; Parse and add a list of lines of assembler code.
;;;
(defun insert-new-lines (asm-heap line-list index)
  (dolist (x line-list)
    (incf index (insert-new-line asm-heap x index))))

(defmethod apply-mutation ((asm asm-heap) (mutation simple-cut))
  "Implement simple-cut mutation on ASM-HEAP."
  (vector-cut (genome asm) (targets mutation))
  asm)

(defmethod apply-mutation ((asm asm-heap) (mutation simple-insert))
  "Insert a value into location of ASM as specified by MUTATION."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    (vector-insert (genome asm)
                   (first bad-good)
                   (aref (genome asm) (second bad-good))))
  asm)

(defmethod apply-mutation ((asm asm-heap) (mutation simple-swap))
  "Swap the values at two locations in ASM as specified by MUTATION."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    (with-slots (genome) asm
      (rotatef (aref genome (first bad-good)) (aref genome (second bad-good))))
    asm))

(defun asm-heap-subseq (asm start &optional end)
  "Create a new mutated asm-heap.
The new genome contains only the elements in the designated range."
  (let* ((new (copy asm))
	 (genome (genome new))
	 (new-genome (line-heap-copy (subseq genome start end))))
    (setf (genome new) new-genome)
    new))

(defmethod apply-mutation ((asm asm-heap) (mutation asm-replace-operand))
  "Apply an asm-replace-operand MUTATION to ASM-HEAP, return the resulting 
software. The MUTATION targets are a pair of instruction indices pointing 
to a \"bad\" instruction (whose operand will be replaced) and 
a \"good\" instruction (whose operand will be used as the replacement). 
If either instruction lacks an operand, a `no-mutation-targets' condition 
is raised."
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    ;; NOTE: assumes instructions start with :code symbol
    (let* ((genome (genome asm))
           (bad (first bad-good))
	   (good (second bad-good))
           (bad-instr (elt genome bad))
	   (good-instr (elt genome good))
           (bad-operands (asm-line-info-operands bad-instr))
           (good-operands (asm-line-info-operands good-instr)))
      (when (or (null bad-operands) (null good-operands))
        (error (make-condition 'no-mutation-targets
                               :text "No operands in instruction(s)"
                               :obj asm)))
      (let ((new-instr (copy-asm-line-info bad-instr)))
	;; update one of the operands with a randomly selected operand from
	;; the good statement
	(setf (elt (asm-line-info-operands new-instr)
		   (random (length (asm-line-info-operands new-instr))))
	      (random-elt good-operands))
	;; update the text since we changed the operand
	(update-asm-line-info-text new-instr)
	;; update the genome with the newly modified instruction
        (setf (elt genome bad) new-instr)  
        asm))))

(defmethod pick-mutation-type ((asm asm-heap))
  (random-pick *simple-mutation-types*))


#|
   Not implemented yet --RGC

(defmethod one-point-crossover ((a sw-range) (b sw-range))
  "DOCFIXME"
  (assert (eq (reference a) (reference b)) (a b)
          "Can not crossover range objects with unequal references.")
  (let ((range (min (size a) (size b))))
    (if (> range 0)
        (let ((point (random range))
              (new (copy a)))
          (setf (genome new)
                (copy-seq (append (range-subseq (genome a) 0 point)
                                  (range-subseq (genome b) point))))
          (values new point))
        (values (copy a) 0))))

(defmethod two-point-crossover ((a sw-range) (b sw-range))
  "DOCFIXME"
  (let ((range (min (size a) (size b))))
    (if (> range 0)
        (let ((points (sort (loop :for i :below 2 :collect (random range)) #'<))
              (new (copy a)))
          (setf (genome new)
                (copy-seq
                 (append
                  (range-subseq (genome b) 0 (first points))
                  (range-subseq (genome a) (first points) (second points))
                  (range-subseq (genome b) (second points)))))
          (values new points))
        (values (copy a) nil))))

(setf *orig* (from-file (make-instance
                   'asm-heap)
                  (make-pathname
                   :name "calc.null"
                   :type "asm"
                   :directory "/u1/rcorman/synth/shaker/test/etc/calc/GTX.FILES")))
|#
