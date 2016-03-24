;;; lexicase selection

;;; Fitness values should be a vector of the form:
;;; #( ("label0" . score0) ("label1" . score1) ... ("labeln" . scoren))

;;; Where each pair represents a single test case or objective. The
;;; labels are purely for human consumption and are otherwise
;;; ignored. All fitness values in the same population must be the
;;; same length and have their scores in the same order.

(defvar *lexicase-predicate* #'>
  "Function to compare individual scores in the test vector.")

(defun lexicase-select (population max-size &aux new-pop)
  "Choose max-size individuals from the population by lexicase
selection. The same individual may be selected multiple times."

  (let ((fitness-length (length (fitness (first population)))))
    ;; All fitness vectors must be the same length
    (loop :for p :in population
       :do (assert (eq (length (fitness p)) fitness-length)))

    (dotimes (n max-size new-pop)
      (push (lexicase-select-one population
                                 (shuffle (range (- fitness-length 1))))
            new-pop))))

(defun lexicase-select-one (population order)
  "Choose a single individual by lexicase selection."
  (loop :for which-test :in order
     :do
     (let ((best (extremum
                  (mapcar [#'cdr {elt _ which-test} #'fitness] population)
                  *lexicase-predicate*)))
       ;; Pick individuals with the highest score on the current test.
       (setf population
             (remove-if-not (lambda (obj)
                              (= (cdr (elt (fitness obj) which-test)) best))
                            population))
       ;; Stop when we get down to one individual
       (when (not (cdr population)) (return))))
  ;; If there's still a tie after all tests, choose randomly.
  (random-elt population))