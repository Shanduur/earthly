#!/bin/bash
set -xeu

function cleanup() {
    status="$?"
    jobs="$(jobs -p)"
    if [ -n "$jobs" ]
    then
        # shellcheck disable=SC2086 # Intended splitting of
        kill $jobs
    fi
    wait
    if [ "$status" = "0" ]; then
      echo "buildkite-test passed"
    else
      echo "buildkite-test failed with $status"
    fi
}
trap cleanup EXIT

os="$(uname)"
arch="$(uname -m)"

if [ "$os" = "Darwin" ]; then
    if [ "$arch" = "arm64" ]; then
        EARTHLY_OS="darwin-m1"
        download_url="https://github.com/earthly/earthly/releases/latest/download/earthly-darwin-arm64"
        earthly="./build/darwin/arm64/earthly"
    else
        EARTHLY_OS="darwin"
        download_url="https://github.com/earthly/earthly/releases/latest/download/earthly-darwin-amd64"
        earthly="./build/darwin/amd64/earthly"
    fi
elif [ "$os" = "Linux" ]; then
    EARTHLY_OS="linux"
    download_url="https://github.com/earthly/earthly/releases/latest/download/earthly-linux-amd64"
    earthly="./build/linux/amd64/earthly"
else
    echo "failed to handle $os, $arch"
    exit 1
fi

echo "The detected architecture of the runner is $(uname -m)"

if ! git symbolic-ref -q HEAD >/dev/null; then
    echo "Add branch info back to git (Earthly uses it for tagging)"
    git checkout -B "$BUILDKITE_BRANCH" || true
fi

echo "Download latest Earthly binary"
if [ -n "$download_url" ]; then
    curl -o ./earthly-released -L "$download_url" && chmod +x ./earthly-released
    released_earthly=./earthly-released
fi

echo "Prune cache for cross-version compatibility"
"$released_earthly" prune --reset

echo "Build latest earthly using released earthly"
"$released_earthly" --version
"$released_earthly" config global.disable_analytics true
"$released_earthly" +for-"$EARTHLY_OS"
chmod +x "$earthly"

EARTHLY_VERSION_FLAG_OVERRIDES="$(tr -d '\n' < .earthly_version_flag_overrides)"
export EARTHLY_VERSION_FLAG_OVERRIDES

# WSL2 sometimes gives a "Text file busy" when running the native binary, likely due to crossing the WSL/Windows divide.
# This should be enough retry to skip that, and fail if theres _actually_ a problem.
att_max=5
att_num=1
until "$earthly" --version || (( att_num == att_max ))
do
    echo "Attempt $att_num failed! Trying again in $att_num seconds..."
    sleep $(( att_num++ ))
done

"$earthly" config global.conversion_parallelism 5

export EARTHLY_VERSION_FLAG_OVERRIDES="referenced-save-only"
"$earthly" config global.local_registry_host 'tcp://127.0.0.1:8371'

# Yes, there is a bug in the upstream YAML parser. Sorry about the jank here.
# https://github.com/go-yaml/yaml/issues/423
"$earthly" config global.buildkit_additional_config "'[registry.\"docker.io\"]

 mirrors = [\"registry-1.docker.io.mirror.corp.earthly.dev\"]'"

echo "Execute tests"
"$earthly" --ci -P \
    --build-arg DOCKERHUB_AUTH=true \
    --build-arg DOCKERHUB_USER_SECRET=+secrets/earthly-technologies/dockerhub-mirror/user \
    --build-arg DOCKERHUB_TOKEN_SECRET=+secrets/earthly-technologies/dockerhub-mirror/pass \
    --build-arg DOCKERHUB_MIRROR=registry-1.docker.io.mirror.corp.earthly.dev \
  +test

echo "Execute fail test"
bash -c "! $earthly --ci ./tests/fail+test-fail"
