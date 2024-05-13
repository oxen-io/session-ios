// This build configuration requires the following to be installed:
// Git, Xcode, XCode Command-line Tools, Cocoapods, xcbeautify, xcresultparser, pip

// Log a bunch of version information to make it easier for debugging
local version_info = {
  name: 'Version Information',
  environment: { LANG: 'en_US.UTF-8' },
  commands: [
    'git --version',
    'pod --version',
    'xcodebuild -version',
    'xcbeautify --version',
    'xcresultparser --version',
    'pip --version',
  ],
};

// Intentionally doing a depth of 2 as libSession-util has it's own submodules (and libLokinet likely will as well)
local clone_submodules = {
  name: 'Clone Submodules',
  commands: ['git submodule update --init --recursive --depth=2 --jobs=4'],
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// Cocoapods
//
// Unfortunately Cocoapods has a dumb restriction which requires you to use UTF-8 for the
// 'LANG' env var so we need to work around the with https://github.com/CocoaPods/CocoaPods/issues/6333
local install_cocoapods = {
  name: 'Install CocoaPods',
  environment: { LANG: 'en_US.UTF-8' },
  commands: [
    'pod install || (rm -rf ./Pods && pod install)',
  ],
  depends_on: [
    'Load CocoaPods Cache',
  ],
};

// Load from the cached CocoaPods directory (to speed up the build)
local load_cocoapods_cache = {
  name: 'Load CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/$USER/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/$USER/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/$USER/.cocoapods_cache.lock',
    |||
      if [[ -d /Users/$USER/.cocoapods_cache ]]; then
        cp -r /Users/$USER/.cocoapods_cache ./Pods
      fi
    |||,
    'rm -f /Users/$USER/.cocoapods_cache.lock',
  ],
  depends_on: [
    'Clone Submodules',
  ],
};

// Override the cached CocoaPods directory (to speed up the next build)
local update_cocoapods_cache(depends_on) = {
  name: 'Update CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/$USER/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/$USER/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/$USER/.cocoapods_cache.lock',
    |||
      if [[ -d ./Pods ]]; then
        rsync -a --delete ./Pods/ /Users/$USER/.cocoapods_cache
      fi
    |||,
    'rm -f /Users/$USER/.cocoapods_cache.lock',
  ],
  depends_on: depends_on,
};

local boot_simulator(device_type) = {
  name: 'Boot Test Simulator',
  commands: [
    'devname="Test-iPhone-${DRONE_COMMIT:0:9}-${DRONE_BUILD_EVENT}"',
    'xcrun simctl create "$devname" ' + device_type,
    'sim_uuid=$(xcrun simctl list devices -je | jq -re \'[.devices[][] | select(.name == "\'$devname\'").udid][0]\')',
    'xcrun simctl boot $sim_uuid',

    'mkdir -p build/artifacts',
    'echo $sim_uuid > ./build/artifacts/sim_uuid',
    'echo $devname > ./build/artifacts/device_name',

    'xcrun simctl list -je devices $sim_uuid | jq -r \'.devices[][0] | "\\u001b[32;1mSimulator " + .state + ": \\u001b[34m" + .name + " (\\u001b[35m" + .deviceTypeIdentifier + ", \\u001b[36m" + .udid + "\\u001b[34m)\\u001b[0m"\'',
  ],
};
local sim_keepalive = {
  name: '(Simulator keep-alive)',
  commands: [
    '/Users/$USER/sim-keepalive/keepalive.sh $(<./build/artifacts/sim_uuid)',
  ],
  depends_on: ['Boot Test Simulator'],
};
local sim_delete_cmd = 'if [ -f build/artifacts/sim_uuid ]; then rm -f /Users/$USER/sim-keepalive/$(<./build/artifacts/sim_uuid); fi';

[
  // Unit tests (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['push'] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,

      boot_simulator('com.apple.CoreSimulator.SimDeviceType.iPhone-15'),
      sim_keepalive,
      {
        name: 'Build and Run Tests',
        commands: [
          'NSUnbufferedIO=YES set -o pipefail && xcodebuild test -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -resultBundlePath ./build/artifacts/testResults.xcresult -parallelizeTargets -destination "platform=iOS Simulator,id=$(<./build/artifacts/sim_uuid)" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -collect-test-diagnostics never 2>&1 | xcbeautify --is-ci',
        ],
        depends_on: [
          'Boot Test Simulator',
          'Install CocoaPods',
        ],
      },
      {
        name: 'Unit Test Summary',
        commands: [
          sim_delete_cmd,
          |||
            if [[ -d ./build/artifacts/testResults.xcresult ]]; then
              xcresultparser --output-format cli --failed-tests-only ./build/artifacts/testResults.xcresult
            else
              echo -e "\n\n\n\e[31;1mUnit test results not found\e[0m"
            fi
          |||,
        ],
        depends_on: ['Build and Run Tests'],
        when: {
          status: ['failure', 'success'],
        },
      },
      update_cocoapods_cache(['Build and Run Tests']),
      {
        name: 'Install Codecov CLI',
        commands: [
          'mkdir -p build/artifacts',
          'pip3 install codecov-cli',
          'find $HOME/Library/Python -name codecovcli -print -quit > ./build/artifacts/codecov_path',
          |||
            if [[ ! -s ./build/artifacts/codecov_path ]]; then
              which codecovcli > ./build/artifacts/codecov_path
            fi
          |||,
          '$(<./build/artifacts/codecov_path) --version',
        ],
      },
      {
        name: 'Convert xcresult to xml',
        commands: [
          'xcresultparser --output-format cobertura ./build/artifacts/testResults.xcresult > ./build/artifacts/coverage.xml',
        ],
        depends_on: ['Build and Run Tests'],
      },
      {
        // No token needed for public repos
        name: 'Upload coverage to Codecov',
        commands: [
          '$(<./build/artifacts/codecov_path) upload-process --fail-on-error -f ./build/artifacts/coverage.xml',
        ],
        depends_on: [
          'Convert xcresult to xml',
          'Install Codecov CLI',
        ],
      },
    ],
  },
  // Validate build artifact was created by the direct branch push (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Check Build Artifact Existence',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['push'] } },
    steps: [
      {
        name: 'Poll for build artifact existence',
        commands: [
          './Scripts/drone-upload-exists.sh',
        ],
      },
    ],
  },
  // Simulator build (non-PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Simulator Build',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['pull_request'] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Build',
        commands: [
          'mkdir build',
          'NSUnbufferedIO=YES set -o pipefail && xcodebuild archive -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App Store Release" -sdk iphonesimulator -archivePath ./build/Session_sim.xcarchive -destination "generic/platform=iOS Simulator" | xcbeautify --is-ci',
        ],
        depends_on: [
          'Install CocoaPods',
        ],
      },
      update_cocoapods_cache(['Build']),
      {
        name: 'Upload artifacts',
        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
        commands: [
          './Scripts/drone-static-upload.sh',
        ],
        depends_on: [
          'Build',
        ],
      },
    ],
  },
]
