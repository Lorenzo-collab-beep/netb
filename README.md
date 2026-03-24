NetBridge Tool

This tool is designed to quickly set up a network bridge between a PC and an external device. 
While it should work on any Linux distribution hopefully, it has been specifically tested on Ubuntu 24.04.4 LTS.

Installation
Save the script in any directory (e.g., ~/.netbridge).
To use the commands globally, add this alias to your .bashrc file:

	alias netb='~/.netbridge/netb'

Reload your configuration: source ~/.bashrc
Usage
To see available commands and usage details, simply run without parameters: netb

DHCP Server
The dhcp-server script is useful when your external device is in dynamic DHCP mode. It simplifies the use of isc-dhcp-server.
To use it from anywhere, you can add this dedicated alias to your .bashrc:

	alias dhcp-server='~/.netbridge/dhcp-server/dhcp-server'
_

	Commands:
	dhcp-server start
	dhcp-server stop
	dhcp-server restart
	
For detailed setup instructions, refer to dhcp-server/README.md.

Important Notes
-Ethernet-to-Ethernet mode: When establishing a bridge in eth-to-eth mode, you must specify the destination port.
 Identify Interfaces: Run ip a (or an equivalent command) in your terminal to find the correct interface names before starting.
-Logs: logs are temporarily saved at /tmp/netb-debug.log
