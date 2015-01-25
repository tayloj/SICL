(cl:in-package #:cleavir-internationalization)

(defclass francais (language)
  ())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Methods on LONG-DAY-NAME.

(defmethod long-day-name ((day (eql 1)) (language francais))
  "lundi")

(defmethod long-day-name ((day (eql 2)) (language francais))
  "mardi")

(defmethod long-day-name ((day (eql 3)) (language francais))
  "mercredi")

(defmethod long-day-name ((day (eql 4)) (language francais))
  "jeudi")

(defmethod long-day-name ((day (eql 5)) (language francais))
  "vendredi")

(defmethod long-day-name ((day (eql 6)) (language francais))
  "samedi")

(defmethod long-day-name ((day (eql 7)) (language francais))
  "dimanche")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Methods on SHORT-DAY-NAME.

(defmethod short-day-name ((day (eql 1)) (language francais))
  "lun")

(defmethod short-day-name ((day (eql 2)) (language francais))
  "mar")

(defmethod short-day-name ((day (eql 3)) (language francais))
  "mer")

(defmethod short-day-name ((day (eql 4)) (language francais))
  "jeu")

(defmethod short-day-name ((day (eql 5)) (language francais))
  "ven")

(defmethod short-day-name ((day (eql 6)) (language francais))
  "sam")

(defmethod short-day-name ((day (eql 7)) (language francais))
  "dim")
