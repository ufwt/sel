;;; asm-parse.lisp --- parse assembly code into asm-line-info structs
(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)


(defstruct asm-edit
  "Capture an edit operation (insert, delete, swap, move) for history purposes"
  op        ;; :insert, :delete, :swap, :move
  position  ;; position where a line was inserted into the genome,
            ;; where a line was removed, or a list of source and dest positions for swap/move
  info)     ;; asm-line-info that was deleted or inserted, or list of source/dest info structs
            ;; for swap/move

(defstruct asm-line-info
  text    ;; original text
  tokens  ;; list of tokens after parsing
  type    ;; empty (white space/comments), decl, data, label-decl, op)
  label   ;; for operations which refer to labels
  opcode  ;; for operations
  id      ;; unique index in heap, sequential starting at 0
  orig-file ;; path of the orignal .asm file that was loaded (if any)
  orig-line ;; line number (0-based) of line in original .asm file (if any)
  )
  
(defvar *assembler-x86-readtable* (copy-readtable))

;; 
;; treat some characters such as : and , as special tokens
;;
(set-macro-character #\: (lambda (stream ch)(declare (ignore stream ch)) :colon)
		     nil
		     *assembler-x86-readtable*)

(set-macro-character #\, (lambda (stream ch)(declare (ignore stream ch)) :comma)
		     nil
		     *assembler-x86-readtable*)
;;;
;;; takes a line of text from a .asm file, and, and converts it to tokens
;;;
(defun tokenize-asm-line (line)
  (with-input-from-string (s line)
    (do* ((*readtable* *assembler-x86-readtable*)
	  (result '())
	  (eof (cons 0 0))
	  (token (read s nil eof)(read s nil eof)))
	 ((eq token eof)(nreverse result))
	(push token result))))

(defun token-labelp (token)
  (and (symbolp token)
       (char= (char (symbol-name token) 0) #\$)))

;;;
;;; Given a list of tokens representing the line, returns either of:
;;;     :nothing
;;;     :declaration
;;;     :data
;;;     :label
;;;     :operation
(defun parse-line-type (tokens)
  (cond ((null tokens) ':empty)
	((and (token-labelp (first tokens))  ; is first token a symbol beginning with '$'?
	      (eq (second tokens) :colon)) ; followed by a ':'?
	 ':label-decl)
	((or (member 'db tokens)
	     (member 'dq tokens)
	     (member 'dd tokens)
	     (member 'dw tokens))
	 ':data)
	((member (first tokens) '(align section extern %define global))
	 ':decl)
	((and (token-labelp (first tokens))
	      (eq (second tokens) 'equ))
	 ':decl)
	(t ':op)))     ;; use this as catch-all for anything else

;;;
;;; takes a line of text from a .asm file, and, and returns 1 or 2 asm-line-info structs.
;;; If the line begins with a label, the line is split into two lines: the label,
;;; and the remaining text/tokens. In this case 2 asm-line-info structs are returned.
;;; Otherwise, as single asm-line-info is returned.
;;;
(defun parse-asm-line (line)
  (let* ((tokens (tokenize-asm-line line))
	 (info (make-asm-line-info :text line :tokens tokens)))

    ;; determine type of line
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
		  (if (and next-info (not (eq (asm-line-info-type (car next-info)) ':empty)))  
		      (cons info next-info)  ;; if an empty line follows the label, discard it
		      (progn
			(setf (asm-line-info-text info) line) ;; restore full text line
		        (list info)))))
	(:empty (list info))
	(:op (setf (asm-line-info-opcode info) (first tokens))(list info))
	(:data (list info))
	(:decl (list info))))))


;;; asm-heap software objects
;;
;; An software object which uses less memory. even less memory, but adds some
;; complexity to many genome manipulation methods.
;; The line-heap holds the original lines of the program (before
;; any mutations, along with any new or modified lines appended to the end of
;; the heap. All elements of the genome are references into this line-heap.
;; history is a list of asm-edit structs, representing the edit history. The first
;; item in the list is the newest edit.
;; 
;;
(define-software asm-heap (asm)
  ((line-heap :initarg :line-heap :accessor line-heap)
   (history :initarg :history :accessor history :initform nil))

  (:documentation
   "Alternative to SIMPLE software objects which should use less memory.
Similar to RANGE, but allows for adding and mutating lines, and should be able to handle
type of mutation we need. The GENOME is a vector of references into the asm-heap (asm-line-info) describes the code."))

(defmethod size ((asm asm-heap))
  "Returns the number of lines in the program, which is just the length of the genome"
  (length (genome asm)))

(defun line-heap-copy (heap)
  (let ((new (make-array (length heap) :fill-pointer (length heap)
			 :adjustable t :initial-contents heap)))
    new))

#| I don't think we need this, since we fixed the default genome copier
(defmethod copy ((asm asm-heap))
  "Customized copy for `asm-heap' software objects.
Ensures deep copies are made of the genome but shallow copies
are made of the other slots."
  (with-slots (fitness genome addr-map linker flags line-heap history) asm
    (make-instance (type-of asm)
		   :fitness fitness
		   :addr-map (addr-map asm)
		   :linker linker
		   :flags flags
		   :history history
		   :line-heap line-heap)))          ;; don't copy the heap, all mutations share it
|#

(defmethod lines ((asm asm-heap))
  "Returns the list of text lines of the genome"
  (map 'list 'asm-line-info-text (genome asm)))

(defmethod (setf lines) (asm-lines (asm asm-heap))
  "Initializes the line-heap, by converting the passed list of lines to
ASM-LINE-INFO structs, and storing them in a vector on the LINE-HEAP"
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
	   (heap (make-array size :fill-pointer size :adjustable t :initial-contents asm-infos)))
      (setf (line-heap asm) heap)
      (setf (genome asm)(line-heap-copy heap)))))  ;; make a copy for this instance 

(defmethod from-file ((asm asm-heap) file)
  "Initialize an `asm-heap' software object from a file."
  (setf (lines asm) (split-sequence #\Newline (file-to-string file)))
  ;; tag all the heap entries with the original file name
  (map nil (lambda (info) (setf (asm-line-info-orig-file info) file)) (line-heap asm))
  asm)

(defun vector-cut (a index)
  "Destructively removes an element from a vector with a fill pointer, returning the element"
  (let ((deleted (aref a index)))
    (do ((i index (+ i 1)))
	((= i (- (length a) 1))(decf (fill-pointer a)))
      (setf (aref a i)(aref a (+ i 1))))
    deleted))

(defun vector-insert (a index val)
  "Destructively inserts an object into a vector with a fill pointer. Returns the object inserted."
  (vector-push-extend 0 a)      ;; increase size by 1 (will be resized if necessary)
  (do ((i (- (length a) 1) (- i 1)))
      ((= i index)(setf (aref a i) val)) 
    (setf (aref a i)(aref a (- i 1))))) 
  
(defun asm-heap-cut (asm index)
  "Create new mutated asm-heap, deleting line-info at index from GENOME"
  (let* ((new (copy asm))
         (genome (genome new))
	 (item (vector-cut genome index)))
    (with-slots (history) new
      (push (make-asm-edit :op :delete :position index :info item) history)) 
    new))
       
(defun asm-heap-insert (asm index val)
  "Create new mutated asm-heap, with added line-info in GENOME"
  (assert (asm-line-info-p val)(val)
            "Requires valid ASM-LINE-INFO in all slots of the line-heap.")
  (let* ((new (copy asm))
         (genome (genome new)))
    (vector-insert genome index val)
    (with-slots (history) new
      (push (make-asm-edit :op :insert :position index :info val) history)) 
    new))

(defun asm-heap-swap (asm i1 i2)
  "Create a new mutated asm-heap. Set value of I1 to the value stored at I2, 
and set I2 to value stored at I1, in GENOME."
  (let* ((new (copy asm))
	 (genome (genome new))
	 (item1 (aref genome i1))
	 (item2 (aref genome i2)))
    (rotatef (aref genome i1) (aref genome i2))
    (with-slots (history) new
      (push (make-asm-edit :op :swap :position (list i1 i2) :info (list item1 item2)) history)) 
    new))
  
(defmethod apply-mutation ((asm asm-heap) (mutation simple-cut))
  "Implement simple-cut mutation on ASM-HEAP"
  (asm-heap-cut asm (targets mutation)))

;;;
;;; This is probably not correct--need to clarify what simple-insert mutation
;;; looks like in this case
;;;
#|
(defmethod apply-mutation ((asm asm-heap) (mutation simple-insert))
  "Implement simple-insert mutation on ASM-HEAP"
  (asm-heap-insert asm (targets mutation)))
|#

(defmethod apply-mutation ((asm asm-heap) (mutation simple-swap))
  "Implement simple-swap mutation on ASM-HEAP"
  (let ((bad-good (targets mutation)))
    (assert (listp bad-good) (mutation)
            "Requires mutations targets to be a list of two elements.")
    (let ((pt1 (first bad-good))
          (pt2 (second bad-good)))
      (asm-heap-swap asm pt1 pt2))))

(defun asm-heap-subseq (asm start &optional end)
  "Create a new mutated asm-heap. The new genome contains only the elements
in the designated range."
  (let* ((new (copy asm))
	 (genome (genome new))
	 (new-genome (line-heap-copy (subseq genome start end))))
    (setf (genome new) new-genome)
    new))


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
