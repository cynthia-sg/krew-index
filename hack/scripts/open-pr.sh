#!/bin/bash

# Copyright AppsCode Inc.
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

set -eou pipefail

SCRIPT_ROOT=$(realpath $(dirname "${BASH_SOURCE[0]}")/../..)
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")

pushd $SCRIPT_ROOT

# http://redsymbol.net/articles/bash-exit-traps/
function cleanup() {
    popd
}
trap cleanup EXIT

source $SCRIPT_ROOT/hack/scripts/common.sh

if [ -z "$1" ]; then
    echo "Missing argument for plugin directory."
    echo "Correct usage: $SCRIPT_NAME <path_to_plugin_repo> <plugin_name>."
    exit 1
fi
if [ -z "$2" ]; then
    echo "Missing argument for plugin name."
    echo "Correct usage: $SCRIPT_NAME <path_to_plugin_repo> <plugin_name>."
    exit 1
fi

PLUGIN_ROOT=$1
PLUGIN_NAME=$2

cd $PLUGIN_ROOT

GIT_TAG=${GITHUB_REF#'refs/tags/'}
PRODUCT_LINE=${PRODUCT_LINE:-}
RELEASE=${RELEASE:-}
RELEASE_TRACKER=${RELEASE_TRACKER:-}

while IFS=$': \r\t' read -r -u9 marker v; do
    case $marker in
        ProductLine)
            PRODUCT_LINE=$(echo $v | tr -d '\r\t')
            ;;
        Release)
            RELEASE=$(echo $v | tr -d '\r\t')
            ;;
        Release-tracker)
            RELEASE_TRACKER=$(echo $v | tr -d '\r\t')
            ;;
    esac
done 9< <(git tag -l --format='%(body)' $GIT_TAG)

pr_branch=${GITHUB_REPOSITORY}@${GIT_TAG}
if [ ! -z "$PRODUCT_LINE" ] && [ ! -z "$RELEASE" ]; then
    pr_branch=${PRODUCT_LINE}@${RELEASE}
fi

# checkout pr branch
cd $SCRIPT_ROOT
# remove all unstagged changes
git add --all
git stash || true
git stash drop || true
# fetch latest remote
git fetch origin --prune
git gc
# checkout pr branch
if [ -z "$(git ls-remote --heads origin $pr_branch)" ]; then
    # remote branch does NOT exists
    git checkout master
    git branch -D $pr_branch || true
    git checkout -b $pr_branch
else
    git checkout master
    git branch -D $pr_branch || true
    git checkout -b $pr_branch --track origin/$pr_branch
fi

# generate krew manifest
cd $PLUGIN_ROOT
mkdir -p $SCRIPT_ROOT/plugins
make gen-krew-manifest >$SCRIPT_ROOT/plugins/$PLUGIN_NAME.yaml

# commit updated krew manifest
cd $SCRIPT_ROOT
git add --all
# generate commit command
ct_cmd="git commit -a -s -m \"Publish ${GITHUB_REPOSITORY}@${GIT_TAG} plugin\""
ct_cmd="$ct_cmd --message \"ProductLine: $PRODUCT_LINE\""
if [ ! -z "$RELEASE" ]; then
    ct_cmd="$ct_cmd --message \"Release: $RELEASE\""
fi
if [ ! -z "$RELEASE_TRACKER" ]; then
    ct_cmd="$ct_cmd --message \"Release-tracker: $RELEASE_TRACKER\""
fi
# commit
eval "$ct_cmd"
# push successfully or { sleep and retry)
git push -u origin HEAD -f

#  open pr
pr_cmd=$(
    cat <<EOF
hub pull-request \
    --labels automerge \
    --message "Publish $pr_branch plugin" \
    --message "$(git show -s --format=%b)"
EOF
)
# if no Release-tracker: auto merge.
if [ -z "$RELEASE_TRACKER" ]; then
    pr_cmd="$pr_cmd --labels automerge"
fi
eval "$pr_cmd" || true
# if Release-tracker: found, report back.
if [ ! -z "$RELEASE_TRACKER" ]; then
    parse_url $RELEASE_TRACKER
    api_url="repos/${RELEASE_TRACKER_OWNER}/${RELEASE_TRACKER_REPO}/issues/${RELEASE_TRACKER_PR}/comments"
    msg="/krew-manifest github.com/${GITHUB_REPOSITORY} ${GIT_TAG}"
    hub api "$api_url" -f body="$msg"
fi
