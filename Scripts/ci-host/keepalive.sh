#!/usr/bin/env bash

set -e

if ! [[ "$1" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    echo "Error: expected single UDID argument.  Usage: $0 XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" >&2
    exit 1
fi

UDID=$1

cd $(gdirname $(greadlink -f $0))

reset="\e[0m"
red="\e[31;1m"
green="\e[32;1m"
yellow="\e[33;1m"
blue="\e[34;1m"
cyan="\e[36;1m"

if [ -n "$2" ]; then
    gtouch --date "$2" $UDID

    echo -e "\n${green}Started a $2 one-shot cleanup timer for device $cyan$UDID${reset}"

    exit 0
fi

echo -e "\n${green}Starting keep-alive for device $cyan$UDID${reset}"

gtouch --date '30 seconds' $UDID
last_print=0
last_touch=$EPOCHSECONDS
started=$EPOCHSECONDS

function print_state() {
    if ! xcrun simctl list -je devices $UDID |
        jq -er '.devices[][] | "Current state: \u001b[32;1m" + .state + " \u001b[34m(" + .name + ", \u001b[35m" + .deviceTypeIdentifier + ", \u001b[36m" + .udid + "\u001b[34m)\u001b[0m"'; then
            echo -e "Current state: $cyan$UDID ${red}not found$reset"
    fi
}

while true; do
    if [[ $EPOCHSECONDS -gt $((last_touch + 10)) ]]; then
        last_touch=$EPOCHSECONDS
        gtouch --no-create --date '30 seconds' $UDID
    fi

    if [ ! -f $UDID ]; then
        echo -e "$cyan$UDID ${yellow}keep-alive file vanished${reset}"
        if xcrun simctl list -je devices $UDID | jq -e "any(.devices.[][]; .)" >/dev/null; then
            logdir="$(xcrun simctl list devices -je $UDID | jq '.devices[][0].logPath')"
            echo -e "$blue    ... shutting down device${reset}"
            xcrun simctl shutdown $UDID
            print_state
            echo -e "$blue    ... deleting device${reset}"
            xcrun simctl delete $UDID
            print_state
            if [ "$logdir" != "null" ] && [ -d "$logdir" ]; then
                echo -e "$blue    ... deleting log directory $logdir${reset}"
                rm -rf "$logdir"
            fi

        else
            echo -e "\n${yellow}Device ${cyan}$UDID${yellow} no longer exists!${reset}"
        fi

        echo -e "\n${green}All done.${reset}"
        exit 0
    fi

    if [[ $EPOCHSECONDS -gt $((last_print + 30)) ]]; then
        last_print=$EPOCHSECONDS
        print_state
    fi

    if [[ $EPOCHSECONDS -gt $((started + 7200)) ]]; then
        echo -e "${red}2-hour timeout reached; exiting to allow cleanup${reset}"
    fi

    sleep 0.5
done
