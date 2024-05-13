# Xcode simulator keepalive/cleanup

Keep-alive directory for simulators managed by xcode that may be created during
drone CI jobs.

These scripts are placed in a /Users/$USER/sim-keepalive directory; keepalive.sh
is called from a CI job to set up a keepalive, while cleanup.py is intended to
be run once/minute via cron to deal with cleaning up old simulators from killed
CI pipelines.

The directory itself will have files created that look like a UDID and are
checked periodically (by cleanup.py); any that have a timestamp less than the
current time will be deleted.

## Simple timeout

A CI job can invoke the keepalive.sh script with a UDID value and a time
interval: the keepalive script will set up a file that will keep the simulator
alive for the given interval, then deletes it once the interval is passed.  The
script exits immediately in this mode.  Shortly (up to a minute) after the
timestamp is reached the simulator device will be deleted (if it still exists).
For example:

    /Users/$USER/sim-keepalive/keepalive.sh $udid "5 minutes"

for a fixed 5-minute cleanup timeout.

## Indefinite timeout

For a job where the precise time required isn't known or varies significantly
there is a script in this directory that provides a simple keep-alive script
that will create and periodically update the $udid file to keep the simulator
alive.

This is moderately more complex to set up as you must add a parallel job (using
`depends_on`) to the CI pipeline that runs the script for the duration of the
steps that require the simulator:

    /Users/$USER/sim-keepalive/keepalive.sh $udid

the script periodically touches the sim-keepalive/$udid to keep the simulator
alive as long as the keep alive script runs.  To stop the keepalive (i.e. when
the task is done) simply run:

	rm /Users/$USER/sim-keepalive/$udid

which will cause the keepalive script to immediately shut down the simulator
with the given UDID and then exits the keepalive script.

If the pipeline gets killed, the keepalive script stops updating the file and
the simulator will be killed by the periodic cleanup within the next couple
minutes.

# crontab entry

A crontab entry must be added to run the CI user's crontab to periodically run
cleanup.py:

    * * * * * ~/sim-keepalive/cleanup.py
