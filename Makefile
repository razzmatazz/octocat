EMACS_IMAGE ?= silex/emacs:29.4
PROJECT_DIR  := $(shell pwd)
EL_FILES     := octocat.el

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

.PHONY: test
test:
	$(DOCKER) run --rm \
	  -v "$(PROJECT_DIR):/src" \
	  -w /src \
	  $(EMACS_IMAGE) \
	  emacs --batch \
	    --eval "(require 'package)" \
	    --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	    --eval "(package-initialize)" \
	    --eval "(package-refresh-contents)" \
	    --eval "(package-install 'package-lint)" \
	    --eval "(package-install 'magit-section)" \
	    --eval "(require 'checkdoc)" \
	    --eval "(require 'package-lint)" \
	    --eval "(setq checkdoc-spellcheck-documentation-flag nil)" \
	    --eval "(checkdoc-file \"$(EL_FILES)\")" \
	    -f package-lint-batch-and-exit \
	    $(EL_FILES)
