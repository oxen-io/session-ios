#!/usr/bin/env bash
#
# Script used with Drone CI to delete any test simulators created by the pipeline that are older than 1
# hour (the timeout for iOS builds) to ensure we don't waste too much HDD space with test simulators.

dir="$HOME/Library/Developer/CoreSimulator/Devices"

# The $HOME directory for a drone pipeline won't be the directory the simulators are stored in so
# check if it exists and if not, fallback to a hard-coded directory
if [[ ! -d $dir ]]; then
  dir="/Users/drone/Library/Developer/CoreSimulator/Devices"
fi

# Plist file
plist="${dir}/device_set.plist"

if [[ ! -f ${plist} ]]; then
	echo -e "\e[31;1mXCode Simulator list not found.\e[0m"
	exit 1
fi

# Delete any unavailable simulators
xcrun simctl delete unavailable

# Extract all UUIDs from the device_set
uuids=$(grep -Eo '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' "$plist")

# Create empty arrays to store the outputs
uuids_to_keep=()
uuids_to_ignore=()
uuids_to_remove=()

# Find directories older than an hour
while read -r child_dir; do
  # Get the last component of the directory path
  dir_name=$(basename "$child_dir")

  # If the folder is not in the uuids array then add it to the uuids_to_remove
  # array, otherwise add it to uuids_to_ignore
  if ! echo "$uuids" | grep -q "$dir_name"; then
    uuids_to_remove+=("$dir_name")
  else
    uuids_to_ignore+=("$dir_name")
  fi
done < <(find "$dir" -maxdepth 1 -type d -not -path "$dir" -mmin +60)

# Find directories newer than an hour
while read -r child_dir; do
  # Get the last component of the directory path
  dir_name=$(basename "$child_dir")

  # If the folder is not in the uuids array then add it to the uuids_to_keep array
  if ! echo "$uuids" | grep -q "$dir_name"; then
    uuids_to_keep+=("$dir_name")
  fi
done < <(find "$dir" -maxdepth 1 -type d -not -path "$dir" -mmin -60)

# Delete the simulators
if [ ${#uuids_to_remove[@]} -eq 0 ]; then
  echo -e "\e[31mNo simulators to delete\e[0m"
else
  echo -e "\e[31mDeleting ${#uuids_to_remove[@]} old test simulators:\e[0m"
  for uuid in "${uuids_to_remove[@]}"; do
    echo -e "\e[31m    $uuid\e[0m"
    # xcrun simctl delete "$uuid"
  done
fi

# Output the pipeline simulators we are leaving
if [ ${#uuids_to_keep[@]} -gt 0 ]; then
  echo -e "\e[33m\nIgnoring ${#uuids_to_keep[@]} test simulators (might be in use):\e[0m"
  for uuid in "${uuids_to_keep[@]}"; do
  	echo -e "\e[33m    $uuid\e[0m"
  done
fi

# Output the remaining Xcode Simulators
echo -e "\e[32m\nIgnoring ${#uuids_to_ignore[@]} Xcode simulators:\e[0m"
for uuid in "${uuids_to_ignore[@]}"; do
  echo -e "\e[32m    $uuid\e[0m"
done