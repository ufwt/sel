;; Copyright (C) 2011-2013  Eric Schulte
(defpackage :software-evolution
  (:use
   :common-lisp
   :alexandria
   :metabang-bind
   :curry-compose-reader-macros
   :split-sequence
   :cl-ppcre
   :diff
   :elf
   :software-evolution-utility)
  (:shadow :elf :size :type :magic-number :diff :insert)
  (:export
   ;; software objects
   :software
   :define-software
   :edits
   :fitness
   :fitness-extra-data
   :genome
   :phenome
   :evaluate
   :copy
   :size
   :lines
   :line-breaks
   :genome-string
   :mitochondria
   :pick
   :pick-good
   :pick-bad
   :pick-bad-targetted
   :mutate
   :apply-mutation
   :*mutation-stats*
   :*crossover-stats*
   :analyze-mutation
   :mutation-key
   :crossover
   :one-point-crossover
   :two-point-crossover
   :*edit-consolidation-size*
   :*consolidated-edits*
   :*edit-consolidation-function*
   :edit-distance
   :from-file
   :ext
   :clang-w-fodder-setup-db
   :get-vars-in-scope
   :get-indexed-vars-in-scope
   :bind-free-vars
   :prepare-sequence-snippet
   :crossover-2pt-outward
   :crossover-single-stmt
   :clang-tidy
   :clang-format
   :clang-mutate
   :to-file
   :apply-path
   :pick-json
   :to-ast-list
   :all-asts
   :good-asts
   :bad-asts
   :containing-asts
   :to-ast-list-containing-bin-range
   :to-ast-hash-table
   :extend-to-enclosing
   :get-stmt-info
   ;; global variables
   :*population*
   :*max-population-size*
   :*tournament-size*
   :*tournament-eviction-size*
   :*fitness-predicate*
   :*cross-chance*
   :*mut-rate*
   :*fitness-evals*
   :*running*
   ;; clang / clang-w-fodder global variables
   :*clang-full-stmt-bias*
   :*clang-same-class-bias*
   :*fodder-selection-bias*
   :*clang-mutation-cdf*
   :*json-database*
   :*json-database-bins*
   :*json-database-full-stmt-bins*
   :*type-database*
   ;; evolution functions
   :incorporate
   :evict
   :tournament
   :mutant
   :crossed
   :new-individual
   :evolve
   :mcmc
   ;; software backends
   :simple
   :light
   :sw-range
   :diff
   :original
   :asm
   :*asm-linker*
   :elf
   :elf-cisc
   :elf-csurf
   :elf-x86
   :elf-arm
   :elf-risc
   :elf-mips
   :genome-bytes
   :pad
   :nop-p
   :forth
   :lisp
   :clang
   :clang-w-fodder
   :do-not-filter
   :with-class-filter
   :full-stmt-filter
   :recontextualize
   :nesting-depth
   :get-stmt-text
   :is-full-stmt
   :enclosing-full-stmt
   :enclosing-block
   :block-successor
   :show-full-stmt
   :full-stmt-text
   :full-stmt-info
   :full-stmt-successors
   :prepare-code-snippet
   :cil
   :llvm
   :linker
   :flags
   :elf-risc-max-displacement
   :ops                      ; <- might want to fold this into `lines'
   ;; software backend specific methods
   :reference
   :base
   :disasm
   :addresses
   :instrument
   :clang-mito
   :add-macro
   :add-includes-for-function
   :add-type
   :union-mito
   ))
