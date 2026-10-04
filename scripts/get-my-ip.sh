#!/bin/bash
# Prints this Mac's current Wi-Fi (LAN) IP address.
# Run this at the start of every session - Wi-Fi IPs can change.
echo "Interface: en0"
ifconfig en0 | grep 'inet ' | awk '{print "IP Address: " $2}'
echo "Default gateway:"
netstat -nr | grep default | grep en0 | awk '{print "  " $2}'
