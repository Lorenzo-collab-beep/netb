# This is necessary to assign an ip to a plugged device.

installation
# You have to install isc-dhcp-server
    sudo apt update
    sudo apt install isc-dhcp-server


ip range
# To config dhcp server modify this file:
    /etc/dhcp/dhcpd.conf

# es/ add a configuration like this:
    subnet 192.168.2.0 netmask 255.255.255.0 {
	# es/ to assign a specific ip address (192.168.2.41)
        range 192.168.2.41 192.168.2.41;
        option routers 192.168.2.1; 
        option broadcast-address 192.168.2.255; 
        option domain-name-servers 8.8.8.8; 
    }

interface
# Edit this file adding a valid eth interface:
    /etc/default/isc-dhcp-server

# es/ enp0s31f6 is a PCI ethernet interface
    INTERFACESv4="enp0s31f6" 
    INTERFACESv6=""

# See eth interfaces by tipe on terminal $'ip a'
# If you setted up a net bridge check the configuration before start the dhcp server
