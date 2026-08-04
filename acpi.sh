#!/bin/bash

# Get the total duration in seconds for the monitoring from the command-line argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <total_duration_in_seconds>"
    exit 1
fi

total_duration=$1

# Start time in seconds since the epoch
start_time=$(date +%s)

# Infinite loop to monitor power consumption every second
while true
do
    # Get the current time in seconds since the epoch
    current_time=$(date +%s)

    # Calculate the elapsed time
    elapsed_time=$((current_time - start_time))

    # Check if the elapsed time exceeds the total duration
    if [ "$elapsed_time" -ge "$total_duration" ]; then
        echo "Monitoring completed. Total duration: $total_duration seconds."
        break
    fi

    # Get the power consumption and show only the line with 'power1'
    power=$(sensors | grep -i 'power1' | tail -n 1)

    # Display the result
    echo "$power"

    # Wait for 1 second before repeating
    sleep 1
done
