#!/bin/bash

# Copyright 2021 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x

# Make sure docker is installed and configured
./hack/jenkins/installers/check_install_docker.sh
yes|gcloud auth configure-docker
docker login -u ${DOCKERHUB_USER} -p ${DOCKERHUB_PASS}

# Make sure gh is installed and configured
./hack/jenkins/installers/check_install_gh.sh

# Let's make sure we have the newest kicbase reference
curl -L https://github.com/kubernetes/minikube/raw/master/pkg/drivers/kic/types.go --output types-head.go
# kicbase tags are of the form VERSION-TIMESTAMP-PR, so this grep finds that TIMESTAMP in the middle
# if it doesn't exist, it will just return VERSION, which is covered in the if statement below
HEAD_KIC_TIMESTAMP=$(egrep "Version =" types-head.go | cut -d \" -f 2 | cut -d "-" -f 2)
CURRENT_KIC_TS=$(egrep "Version =" pkg/drivers/kic/types.go | cut -d \" -f 2 | cut -d "-" -f 2)
if [[ $HEAD_KIC_TIMESTAMP != v* ]]; then
	diff=$((CURRENT_KIC_TS-HEAD_KIC_TIMESTAMP))
	if [[ $CURRENT_KIC_TS == v* ]] || [ $diff -lt 0 ]; then
		gh pr comment ${ghprbPullId} --body "Hi ${ghprbPullAuthorLoginMention}, your kicbase info is out of date. Please rebase."
		exit 1
	fi
fi
rm types-head.go

# Setup variables
if [[ -z $KIC_VERSION ]]; then
	# Testing PRs here
	release=false
	now=$(date +%s)
	KV=$(egrep "Version =" pkg/drivers/kic/types.go | cut -d \" -f 2 | cut -d "-" -f 1)
	GCR_REPO=gcr.io/k8s-minikube/kicbase-builds
	DH_REPO=kicbase/build
	export KIC_VERSION=$KV-$now-$ghprbPullId
else
	# Actual kicbase release here
	release=true
	GCR_REPO=${GCR_REPO:-gcr.io/k8s-minikube/kicbase}
	DH_REPO=${DH_REPO:-kicbase/stable}
	export KIC_VERSION
fi
GCR_IMG=${GCR_REPO}:${KIC_VERSION}
DH_IMG=${DH_REPO}:${KIC_VERSION}
export KICBASE_IMAGE_REGISTRIES="${GCR_IMG} ${DH_IMG}"


# Build a new kicbase image
yes|make push-kic-base-image

# Abort with error message if above command failed
ec=$?
if [ $ec -gt 0 ]; then
	if [ "$release" = false ]; then
		gh pr comment ${ghprbPullId} --body "Hi ${ghprbPullAuthorLoginMention}, building a new kicbase image failed, please try again."
	fi
	exit $ec
fi

# Retrieve the sha from the new image
docker pull $GCR_IMG
fullsha=$(docker inspect --format='{{index .RepoDigests 0}}' $KICBASE_IMAGE_REGISTRIES)
sha=$(echo ${fullsha} | cut -d ":" -f 2)

if [ "$release" = false ]; then
	# Comment on the PR with the newly built kicbase
	sed_cmd="\`\`\`\\n sed 's|Version = .*|Version = \\\"${KIC_VERSION}\\\"|;s|baseImageSHA = .*|baseImageSHA = \\\"${sha}\\\"|;s|gcrRepo = .*|gcrRepo = \\\"${GCR_REPO}\\\"|;s|dockerhubRepo = .*|dockerhubRepo = \\\"${DH_REPO}\\\"|' pkg/drivers/kic/types.go > new-types.go; mv new-types.go pkg/drivers/kic/types.go; make generate-docs;\\n\`\`\`"

	codeblock="\\n\\t// Version is the current version of kic\\n\\tVersion = \\\"${KIC_VERSION}\\\"\\n\\t// SHA of the kic base image\\n\\tbaseImageSHA = \\\"${sha}\\\"\\n\\t// The name of the GCR kicbase repository\\n\\tgcrRepo = \\\"${GCR_REPO}\\\"\\n\\t// The name of the Dockerhub kicbase repository\\n\\tdockerhubRepo = \\\"${DH_REPO}\\\""

	# Display the message to the user
	message="Hi ${ghprbPullAuthorLoginMention},\\n\\nA new kicbase image is available, please update your PR with the new tag and SHA.\\nIn pkg/drivers/kic/types.go:\\n${codeblock}\\nThen run \`make generate-docs\` to update our documentation to reference the new image.\n\nAlternatively, run the following command and commit the changes:${sed_cmd}\\n"

	gh pr comment ${ghprbPullId} --body "${message}"
else
	# We're releasing, so open a new PR with the newly released kicbase
	git config user.name "minikube-bot"
	git config user.email "minikube-bot@google.com"
	
	branch=kicbase-release-${KIC_VERSION}
	git checkout -b ${branch}

	sed -i "s|Version = .*|Version = \"${KIC_VERSION}\"|;s|baseImageSHA = .*|baseImageSHA = \"${sha}\"|;s|gcrRepo = .*|gcrRepo = \"${GCR_REPO}\"|;s|dockerhubRepo = .*|dockerhubRepo = \"${DH_REPO}\"|" pkg/drivers/kic/types.go

	git add -A
	git commit -m "Update kicbase to ${KIC_VERSION}"
	git remote add minikube-bot git@github.com:minikube-bot/minikube.git
	git push -f minikube-bot ${branch}

	gh pr create --title "Update kicbase to ${KIC_VERSION}" --base kubernetes:master --head minikube-bot:${branch}
fi
