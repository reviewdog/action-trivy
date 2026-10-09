#!/bin/bash

# Print commands for debugging
if [[ "$RUNNER_DEBUG" = "1" ]]; then
  set -x
fi

if [[ -z "${INPUT_TRIVY_COMMAND}" ]]; then
  echo "Error: Missing required input 'trivy_command'."
  exit 1
fi

if [[ -z "${INPUT_TRIVY_TARGET}" ]]; then
  echo "Error: Missing required input 'trivy_target'."
  exit 1
fi

# Fail fast on errors, unset variables, and failures in piped commands
set -Eeuo pipefail

cd "${GITHUB_WORKSPACE}/${INPUT_WORKING_DIRECTORY}" || exit

echo '::group::Preparing ...'
  unameOS="$(uname -s)"
  case "${unameOS}" in
    Linux*)     os=Linux;;
    Darwin*)    os=macOS;;
    CYGWIN*)    os=Windows;;
    MINGW*)     os=Windows;;
    MSYS_NT*)   os=Windows;;
    *)          echo "Unknown system: ${unameOS}" && exit 1
  esac

  unameArch="$(uname -m)"
  case "${unameArch}" in
    x86*)      arch=64bit;;
    aarch64)   arch=ARM64;;
    arm64)     arch=ARM64;;
    *)         echo "Unsupported architecture: ${unameArch}. Only AMD64 and ARM64 are supported by the action" && exit 1
    esac

  case "${os}" in
    Windows)   archive_extension="zip";;
    *)         archive_extension="tar.gz";;
  esac

  TEMP_PATH="$(mktemp -d)"
  echo "Detected ${os} running on ${arch}, will install tools in ${TEMP_PATH}"
  REVIEWDOG_PATH="${TEMP_PATH}/reviewdog"
  TRIVY_PATH="${TEMP_PATH}/trivy"
echo '::endgroup::'

echo "::group::🐶 Installing reviewdog (${REVIEWDOG_VERSION}) ... https://github.com/reviewdog/reviewdog"
  curl -sfL https://raw.githubusercontent.com/reviewdog/reviewdog/9b54cccfb4bf2509aef8a3e26899412348b62ce9/install.sh | GITHUB_TOKEN="${INPUT_GITHUB_TOKEN}" sh -s -- -b "${REVIEWDOG_PATH}" "${REVIEWDOG_VERSION}" 2>&1
echo '::endgroup::'

echo "::group:: Installing trivy (${INPUT_TRIVY_VERSION}) ... https://github.com/aquasecurity/trivy"
  test ! -d "${TRIVY_PATH}" && install -d "${TRIVY_PATH}"

  PREV_DIR=$(pwd)
  TEMP_DOWNLOAD_PATH="$(mktemp -d)"
  cd "${TEMP_DOWNLOAD_PATH}" || exit

  archive="trivy.${archive_extension}"
  if [[ "${INPUT_TRIVY_VERSION}" = "latest" ]]; then
    # latest release is available on this url.
    # document: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
    latest_url="https://github.com/aquasecurity/trivy/releases/latest/"
    release=$(curl $latest_url -s -L -I -o /dev/null -w '%{url_effective}' | awk -F'/' '{print $NF}')
  else
    release="${INPUT_TRIVY_VERSION}"
  fi
  release_num=${release/#v/}
  url="https://github.com/aquasecurity/trivy/releases/download/${release}/trivy_${release_num}_${os}-${arch}.${archive_extension}"
  # Echo url for testing
  echo "Downloading ${url} to ${archive}"
  curl --silent --show-error --fail \
    --location "${url}" \
    --output "${archive}"

  ### TEST
  echo "URL: ${url}"
  echo "ARCHIVE: ${archive}"
  ls
  ### TEST END

  checksum_key="${url##*/}"
  input_checksum="${INPUT_TRIVY_CHECKSUM:-}"

  # Resolve the expected checksum: prefer user-supplied value, fall back to the bundled lookup table
  if [[ -n "${input_checksum}" ]]; then
    # Case 1: user provided a checksum explicitly, use it
    checksum="${input_checksum}"
  else
    # Case 2: no user-provided checksum, look up from trivy_checksums.txt
    stored_checksum=$(grep -m1 -F "${checksum_key}:" "${GITHUB_ACTION_PATH}/trivy_checksums.txt" | awk '{print $2}' || true)
    if [[ -z "${stored_checksum}" ]]; then
      # Case 2.1: not found in trivy_checksums.txt
      echo "WARNING: Skipping integrity check, set 'trivy_checksum' to verify the download."
      checksum=""
    else
      # Case 2.2: found in trivy_checksums.txt
      checksum="${stored_checksum}"
    fi
  fi

  # compare trivy checksum against the downloaded package
  if [[ -n "${checksum}" ]]; then
    echo "Verifying SHA256 checksum ..."
    if command -v sha256sum &>/dev/null; then
      # Linux (coreutils) and Windows Git Bash (mingw-w64-x86_64-coreutils)
      actual=$(sha256sum "${archive}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
      # macOS (perl-based shasum, ships with Xcode CLI tools)
      actual=$(shasum -a 256 "${archive}" | awk '{print $1}')
    else
      echo "ERROR: No SHA256 tool found (sha256sum / shasum)"
      exit 1
    fi

    if [[ "${actual}" != "${checksum}" ]]; then
      echo ""
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "!! ERROR: SHA256 checksum verification FAILED               !!"
      echo "!! The downloaded trivy release may have been tampered with. !!"
      echo "!! Do NOT use this binary.                                   !!"
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo ""
      exit 1
    fi
  fi

  if [[ "${os}" = "Windows" ]]; then
    unzip "${archive}"
  else
    tar -xzf "${archive}"
  fi
  install trivy "${TRIVY_PATH}"
  cd "${PREV_DIR}" || exit
echo '::endgroup::'

echo "::group:: Print trivy details ..."
  "${TRIVY_PATH}/trivy" --version
echo '::endgroup::'

echo '::group:: Running trivy with reviewdog 🐶 ...'
  export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

  # Allow failures now, as reviewdog handles them
  set +Eeuo pipefail

  # shellcheck disable=SC2086
  "${TRIVY_PATH}/trivy" --format sarif ${INPUT_TRIVY_FLAGS:-} --exit-code 1 ${INPUT_TRIVY_COMMAND} ${INPUT_TRIVY_TARGET} 2> /dev/null \
    |  "${REVIEWDOG_PATH}/reviewdog" -f=sarif \
        -name="${INPUT_TOOL_NAME}" \
        -reporter="${INPUT_REPORTER}" \
        -level="${INPUT_LEVEL}" \
        -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
        -fail-level="${INPUT_FAIL_LEVEL}" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        ${INPUT_FLAGS}

  trivy_return="${PIPESTATUS[0]}" reviewdog_return="${PIPESTATUS[1]}" exit_code=$?
  echo "trivy-return-code=${trivy_return}" >> "$GITHUB_OUTPUT"
  echo "reviewdog-return-code=${reviewdog_return}" >> "$GITHUB_OUTPUT"
echo '::endgroup::'

exit "${exit_code}"
