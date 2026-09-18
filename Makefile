EMACS ?= emacs

.PHONY: compile test clean

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile ddskk-jev.el

test: compile
	$(EMACS) -Q --batch -L . -L test \
	  -l ddskk-jev-test -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
