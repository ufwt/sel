;;; Concrete implementation of the database interface
;;; for an external JSON fodder database parsed and stored
;;; entirely within the current LISP image
(in-package :software-evolution)

(defclass json-database (in-memory-database)
  ((json-stream
    :initarg :json-stream :accessor json-stream
    :initform (error "JSON-STREAM field is required for DATABASE.")
    :documentation "Stream of incoming JSON.")))

(defmethod print-object ((db json-database) stream)
  (print-unreadable-object (db stream :type t)
    (when (subtypep (type-of (json-stream db)) 'file-stream)
      (format stream "~a:" (pathname (json-stream db))))
    (prin1 (length (ast-database-list db)) stream)))

(defmethod initialize-instance :after ((db json-database) &key)
  ;; Initialize (load) a new json database.
  (dolist (snippet (shuffle (load-json-with-caching db)))
    (let ((ast-class (aget :ast-class snippet)))
      (if ast-class
          ;; This entry describes a code snippet
          (progn
            (setf (ast-database-list db)
                  (cons snippet (ast-database-list db)))
            (setf (ast-database-full-stmt-list db)
                  (if (aget :full-stmt snippet)
                      (cons snippet (ast-database-full-stmt-list db))
                      (ast-database-full-stmt-list db)))
            (let ((cur (gethash ast-class (ast-database-ht db))))
              (setf (gethash ast-class (ast-database-ht db))
                    (cons snippet cur))))
          ;; This entry describes a type, perhaps
          (let ((type-id (aget :hash snippet)))
            (when type-id
              (setf (gethash type-id (type-database-ht db)) snippet)))))))

(defmethod load-json-with-caching ((db json-database))
  (let ((json:*identifier-name-to-key* 'se-json-identifier-name-to-key))
    (if (subtypep (type-of (json-stream db)) 'file-stream)
        (let* ((json-db-path (pathname (json-stream db)))
               (json-stored-db-path (make-pathname
                                     :directory (pathname-directory json-db-path)
                                     :name (pathname-name json-db-path)
                                     :type "dbcache")))
          (if (and (probe-file json-stored-db-path)
                   (> (file-write-date json-stored-db-path)
                      (file-write-date json-db-path)))
              ;; Cache exists and is newer than the original
              ;; JSON database; use the cache.
              (cl-store:restore json-stored-db-path)
              ;; Cache does not yet exist or has been invalidated;
              ;; load from JSON and write back to the cache.
              (cl-store:store (json:decode-json-from-source (json-stream db))
                              json-stored-db-path)))
        (json:decode-json-from-source (json-stream db)))))

