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

.PHONY: image compile lint test ci

image:
	$(DOCKER) build -t $(LOCAL_IMAGE) .

compile: image
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask compile"

lint: image
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask lint checkdoc && eask lint package"

test: image
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask test ert test/octocat-tests.el"

ci: compile lint test
