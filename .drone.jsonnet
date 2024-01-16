// Log a bunch of version information to make it easier for debugging
local version_info = {
  name: 'Version Information',
  commands: [
    'git --version',
    'pod --version',
    'xcodebuild -version'
  ]
};

// Intentionally doing a depth of 2 as libSession-util has it's own submodules (and libLokinet likely will as well)
local clone_submodules = {
  name: 'Clone Submodules',
  commands: ['git fetch --tags', 'git submodule update --init --recursive --depth=2']
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// Cocoapods
// 
// Unfortunately Cocoapods has a dumb restriction which requires you to use UTF-8 for the
// 'LANG' env var so we need to work around the with https://github.com/CocoaPods/CocoaPods/issues/6333
local install_cocoapods = {
  name: 'Install CocoaPods',
  commands: ['
    LANG=en_US.UTF-8 pod install || rm -rf ./Pods && LANG=en_US.UTF-8 pod install
  '],
  depends_on: [
    'Load CocoaPods Cache'
  ]
};

// Load from the cached CocoaPods directory (to speed up the build)
local load_cocoapods_cache = {
  name: 'Load CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d /Users/drone/.cocoapods_cache ]]; then
        cp -r /Users/drone/.cocoapods_cache ./Pods
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: [
    'Clone Submodules'
  ]
};

// Override the cached CocoaPods directory (to speed up the next build)
local update_cocoapods_cache(depends_on) = {
  name: 'Update CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d ./Pods ]]; then
        rm -rf /Users/drone/.cocoapods_cache
        cp -r ./Pods /Users/drone/.cocoapods_cache
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: depends_on,
};

// Run specified unit tests
local run_tests(testName, testBuildStepName) = {
  name: 'Run ' + testName,
  commands: [
    'NSUnbufferedIO=YES set -o pipefail && xcodebuild test-without-building -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -destination "platform=iOS Simulator,name=iPhone 14" -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -only-testing ' + testName + ' -collect-test-diagnostics never 2>&1 | ./Pods/xcbeautify/xcbeautify --is-ci',
  ],
  depends_on: [
    testBuildStepName
  ],
};


[
  // Unit tests
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests',
    platform: { os: 'darwin', arch: 'amd64' },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Reset Simulators',
        commands: [
          'xcrun simctl shutdown all',
          'xcrun simctl erase all'
        ],
        depends_on: [
          'Install CocoaPods'
        ]
      },
      {
        name: 'Build For Testing',
        commands: [
          'mkdir build',
          'xcodebuild build-for-testing -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -destination "platform=iOS Simulator,name=iPhone 14" | ./Pods/xcbeautify/xcbeautify --is-ci',
        ],
        depends_on: [
          'Install CocoaPods'
        ],
      },
      run_tests('SessionTests', 'Build For Testing'),
      run_tests('SessionMessagingKitTests', 'Build For Testing'),
      run_tests('SessionSnodeKitTests', 'Build For Testing'),
      run_tests('SessionUtilitiesKitTests', 'Build For Testing'),
      {
        name: 'Shutdown Simulators',
        commands: [ 'xcrun simctl shutdown all' ],
        depends_on: [
          'Build For Testing',
          'Run SessionTests',
          'Run SessionMessagingKitTests',
          'Run SessionSnodeKitTests',
          'Run SessionUtilitiesKitTests'
        ],
        when: {
          status: ['failure', 'success']
        }
      },
      update_cocoapods_cache(['Build For Testing'])
    ],
  },
  // Simulator build
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Simulator Build',
    platform: { os: 'darwin', arch: 'amd64' },
    trigger: { event: { exclude: [ 'pull_request' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Build',
        commands: [
          'mkdir build',
          'xcodebuild archive -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App_Store_Release" -sdk iphonesimulator -archivePath ./build/Session_sim.xcarchive -destination "generic/platform=iOS Simulator" | ./Pods/xcbeautify/xcbeautify --is-ci',
        ],
        depends_on: [
          'Install CocoaPods'
        ],
      },
      update_cocoapods_cache(['Build']),
      {
        name: 'Upload artifacts',
        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
        commands: [
          './Scripts/drone-static-upload.sh'
        ],
        depends_on: [
          'Build'
        ]
      },
    ],
  },
  // AppStore build (generate an archive to be signed later)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'AppStore Build',
    platform: { os: 'darwin', arch: 'amd64' },
    trigger: { event: { exclude: [ 'pull_request' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Build',
        commands: [
          'mkdir build',
          'xcodebuild archive -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App_Store_Release" -sdk iphoneos -archivePath ./build/Session.xcarchive -destination "generic/platform=iOS" -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO | ./Pods/xcbeautify/xcbeautify --is-ci',
        ],
        depends_on: [
          'Install CocoaPods'
        ],
      },
      update_cocoapods_cache(['Build']),
      {
        name: 'Upload artifacts',
        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
        commands: [
          './Scripts/drone-static-upload.sh'
        ],
        depends_on: [
          'Build'
        ]
      },
    ],
  },
]