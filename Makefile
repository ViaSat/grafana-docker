# Makefile for grafana-docker
# This does everything that build.sh does and then some:
#   Adds support for Artifactory storage of grafana .deb in addition to AWS S3
#   Tests access to grafana .deb before launching docker build and provides a useful complaint on failure
#   Supports authentication on .deb store (typically needed for Artifactory)
#   Supports command line selectable docker --no-cache option

# artifact_store can be 'artifactory' or 's3'
artifact_store := artifactory

# vars from command line
# IF GRAFANA_VERSION is not set it defaults to 'latest' and the tag is set to 'master', and the 'latest' tag is not applied
#   only applicable to official Grafana s3 store
# if DOCKER_TAG is not set, docker image will be tagged with GRAFANA_VERSION
# if TAG_LATEST is set, then the docker 'latest' tag will be moved to this build
# set DOCKER_NO_CACHE if you changed the Dockerfile and need to force --no-cache behavior

GRAFANA_VERSION :=
DOCKER_TAG :=
TAG_LATEST :=
docker_cache_arg :=

ifdef DOCKER_NO_CACHE
docker_cache_arg := --no-cache
endif

ifdef GRAFANA_VERSION
ifndef DOCKER_TAG
	DOCKER_TAG :=$(GRAFANA_VERSION)
endif
else
ifeq ($(artifact_store), s3)
	GRAFANA_VERSION := latest
	DOCKER_TAG := master
	TAG_LATEST :=
else
$(error Grafana latest/master version fetch not supported in artifactory)
endif
endif

grafana_artifact_filename := grafana_$(GRAFANA_VERSION)_amd64.deb

# set up artifact store specific mechanics
# Must define
#   download_url - options and URL for the curl operation in the Dockerfile
#   curl_get_url - URL to the artifact
#   curl_info_args - curl args and URL used to test access to the artifact

ifeq ($(artifact_store), artifactory)
#
# Artifactory source for .deb
#
artifactory_base_url := https://artifactory.viasat.com/artifactory
grafana_subrepo := databus-deb/grafana

curl_get_base := $(artifactory_base_url)/$(grafana_subrepo)

# artifactory creds needed if .deb source is artifactory
ifndef ARTIFACTORY_USERNAME
$(error ARTIFACTORY_USERNAME must be defined)
endif
ifndef ARTIFACTORY_PASSWORD
$(error ARTIFACTORY_PASSWORD must be defined)
endif
curl_creds := -u $(ARTIFACTORY_USERNAME):$(ARTIFACTORY_PASSWORD)

# Artifactory File Info API will verify accessibility in a few seconds
artifactory_api_info := $(artifactory_base_url)/api/storage
artifactory_info_uri := $(artifactory_api_info)/$(grafana_subrepo)/$(grafana_artifact_filename)

curl_get_url := $(curl_get_base)/$(grafana_artifact_filename)
curl_info_args := $(curl_creds) --write-out "\nhttp_status: %{http_code}\n" $(artifactory_info_uri)
download_url := "$(curl_creds) $(curl_get_url)"

# this could be used to do the actual get
#curl_get_args  := -u $(ARTIFACTORY_USERNAME):$(ARTIFACTORY_PASSWORD) --write-out "\nhttp_status: %{http_code}\n" -O $(curl_get_url)

else ifeq ($(artifact_store), s3)
#
# S3 bucket source for .deb
#
ifeq ($(DOCKER_TAG), master)
s3_region := s3-us-west-2
s3_bucketpath := master
else
s3_bucketpath := release
endif

# This URL is used in grafana's build.sh but thus far only holds 4.2.0-preXXXX builds
curl_get_url := https://grafana-releases.$(s3_region).amazonaws.com/$(s3_bucketpath)/$(grafana_artifact_filename)

# This URL seems to have everything and is currently needed if you want release builds prior to 4.2
curl_get_url := https://grafanarel.s3.amazonaws.com/builds/$(grafana_artifact_filename)

curl_info_args := --write-out "\nhttp_status: %{http_code}\n" $(curl_get_url)
download_url := $(curl_get_url)

else
$(error artifact_store $(artifact_store) not supported yet)
endif

tmpfile:=$(shell mktemp /tmp/grafanabuild.XXXXXX)

# Pre-check artifact access to avoid lengthy fail/debug cycles inside the docker build
.PHONY: check_artifact
check_artifact:
	@echo Testing $(artifact_store) curl target
	curl $(curl_info_args) 2>/dev/null > $(tmpfile)
	if [[ -z `grep 200 $(tmpfile)` ]]; then echo "Error checking artifact curl"; cat $(tmpfile); rm $(tmpfile); false; fi
	rm $(tmpfile)

# Build the grafana docker image from the .deb
.PHONY: build
build: check_artifact
	@echo "GRAFANA_VERSION = "$(GRAFANA_VERSION)
	@echo "DOCKER_TAG = "$(DOCKER_TAG)
	@echo "TAG_LATEST ="$(TAG_LATEST)
	@echo Building version tagged docker image
	docker build --build-arg GRAFANA_VERSION=$(GRAFANA_VERSION) --build-arg DOWNLOAD_URL=$(download_url) --tag "grafana/grafana:$(DOCKER_TAG)"  $(docker_cache_arg) .
ifdef TAG_LATEST
	@echo Tagging release image as latest
	docker tag grafana/grafana:$(DOCKER_TAG) grafana/grafana:latest
endif

# update from fork origin by merging upstream/master to this repo
.PHONY: update-from-upstream
update-from-upstream:
	git fetch upstream
	git checkout master
	git merge upstream/master

