#!/bin/bash
# Check if the StarRupture server process is running
pgrep -f "StarRuptureServerEOS" > /dev/null 2>&1
