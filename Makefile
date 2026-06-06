EMACS_BASE_IMAGE ?= silex/emacs:29.4
TEST_IMAGE       := octocat-test
PROJECT_DIR      := $(shell pwd)
EL_FILES         := octocat-core.el octocat-pr.el octocat.el
PLATFORM         ?= linux/arm64

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

.PHONY: test image

image:
	$(DOCKER) build --platform $(PLATFORM) --build-arg BASE=$(EMACS_BASE_IMAGE) -t $(TEST_IMAGE) .

test: image
	$(DOCKER) run --rm \
	  --platform $(PLATFORM) \
	  -v "$(PROJECT_DIR):/src" \
	  -w /src \
	  $(TEST_IMAGE) \
	  emacs --batch \
	    --eval "(require 'package)" \
	    --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	    --eval "(package-initialize)" \
	    --eval "(package-refresh-contents)" \
	    --eval "(package-install 'package-lint)" \
	    --eval "(package-install 'magit-section)" \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    --eval "(add-to-list 'load-path \".\")" \
	    --eval "(dolist (f '($(foreach f,$(EL_FILES),\"$(f)\"))) (byte-compile-file f))" \
	    --eval "(require 'checkdoc)" \
	    --eval "(require 'package-lint)" \
	    --eval "(setq checkdoc-spellcheck-documentation-flag nil)" \
	    --eval "(dolist (f '($(foreach f,$(EL_FILES),\"$(f)\"))) (checkdoc-file f))" \
	    -f package-lint-batch-and-exit \
	    $(EL_FILES)
