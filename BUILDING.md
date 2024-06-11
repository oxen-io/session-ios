# Building

We typically develop against the latest stable version of Xcode.

As of this writing, that's Xcode 12.4

## Prerequistes

Install [CocoaPods](https://guides.cocoapods.org/using/getting-started.html).

## 1. Clone

Clone the repo to a working directory:

```
git clone https://github.com/oxen-io/session-ios.git
```

**Recommendation:**

We recommend you fork the repo on GitHub, then clone your fork:

```
git clone https://github.com/<USERNAME>/session-ios.git
```

You can then add the Session repo to sync with upstream changes:

```
git remote add upstream https://github.com/oxen-io/session-ios
```

## 2. Submodules

Session requires a number of submodules to build, these can be retrieved by navigating to the project directory and running:

```
git submodule update --init --recursive
```

## 3. Pods

To build and configure the libraries Session uses, just run:

```
pod install
```

## 4. libSession build dependencies

The iOS project has a share C++ library called `libSession` which is built as one of the project dependencies, in order for this to compile the following dependencies need to be installed:
- cmake
- m4
- pkg-config

These can be installed with Homebrew via `brew install cmake m4 pkg-config`

Additionally `xcode-select` needs to be setup correctly (depending on the order of installation it can point to the wrong directory and result in a build error similar to `tool '{name}' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance`), this can be setup correctly by running:

`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

## 5. Xcode

Open the `Session.xcworkspace` in Xcode.

```
open Session.xcworkspace
```

In the TARGETS area of the General tab, change the Team dropdown to
your own. You will need to do that for all the listed targets, e.g.
Session, SessionShareExtension, and SessionNotificationServiceExtension. You
will need an Apple Developer account for this.

On the Capabilities tab, turn off Push Notifications and Data Protection,
while keeping Background Modes on. The App Groups capability will need to
remain on in order to access the shared data storage.

Build and Run and you are ready to go!

## Known issues

### Third-party Installation
The database for the app is stored within an `App Group` directory which is based on the app identifier, unfortunately the identifier cannot be retrieved at runtime so it's currently hard-coded in the code. In order to be able to run session on a device you will need to update the `UserDefaults.applicationGroup` variable in `SessionUtilitiesKit/General/SNUserDefaults` to match the value provided (You may also need to create the `App Group` on your Apple Developer account).

### Push Notifications
Features related to push notifications are known to be not working for
third-party contributors since Apple's Push Notification service pushes
will only work with the Session production code signing
certificate.
