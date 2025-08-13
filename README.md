# makeKiosk
A script that converts a vanilla install of Ubuntu into a web kiosk 


This script should be run as root. 
- It will install Chromium and configure ubuntu to boot and automatically launch chromium. 
- Chromium will run in kiosk mode and never show an address bar
- Plymouth will be installed and a simple logo will be displayed during booth with the boot messages scrolling beneath it.
- This script will also set the ubuntu timeouts for DHCP to something reasonable 15 seconds instead of 5 minutes

