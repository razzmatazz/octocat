LOCAL_IMAGE := octocat-test
SRC         := /src

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

DOCKER_RUN = $(DOCKER) run --rm \
               -v "$(CURDIR)":$(SRC) \
               -w $(SRC) \
               $(LOCAL_IMAGE)

.PHONY: image deps compile lint test ci clean

image:
	$(DOCKER) build -t $(LOCAL_IMAGE) .

# Installing dependencies is slow, so only do it when Eask changes.
.eask/deps: Eask | image
	$(DOCKER_RUN) sh -c "eask install-deps --dev"
	touch .eask/deps

deps: .eask/deps

clean:
	find . -maxdepth 1 -name '*.elc' -delete

# Compile a copy, so the .elc files do not land next to the sources while
# lint and test run alongside.
compile: deps
	$(DOCKER_RUN) sh -c "cp -a /src /tmp/build && cd /tmp/build && eask compile --strict"

lint: deps
	$(DOCKER_RUN) sh -c "eask lint checkdoc && eask lint package"

test: deps
	$(DOCKER_RUN) sh -c "eask test ert test/octocat-tests.el && eask test ert test/octocat-evil-repo-tests.el"

# compile, lint and test are independent, so run them in parallel.
ci: clean
	$(MAKE) -j3 compile lint test
