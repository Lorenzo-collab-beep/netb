#!/bin/sh

if [ -z "$1" ]; then
    echo "Use: $0 {start|stop|restart}"
    exit 1
fi

ACTION="$1"

sudo -v

case "$ACTION" in
    start)
        echo "DHCP start..."
        sudo systemctl restart isc-dhcp-server
        sleep 1
        sudo systemctl enable isc-dhcp-server
        sleep 1
        sudo systemctl status isc-dhcp-server
        ;;

    status)
        echo "DHCP status..."
        sudo systemctl status isc-dhcp-server
        ;;

    stop)
        echo "DHCP stop..."
        sudo systemctl stop isc-dhcp-server
        sleep 1
        sudo systemctl disable isc-dhcp-server
        sleep 1
        sudo systemctl status isc-dhcp-server
        ;;

    restart)
        echo "DHCP restart..."
        sudo systemctl restart isc-dhcp-server
        sleep 1
        sudo systemctl status isc-dhcp-server
        ;;

    *)
        echo "Invalid param. Use: start | stop | restart | status"
        exit 1
        ;;
esac
