Design

- This script should be run as root. 
- This script will print a nice progress bar status as it installs and configures ubuntu.
- It will install Chromium and configure ubuntu to boot and automatically launch chromium. 
- Chromium will run in kiosk mode and never show an address bar.
- This script will install Apache and PHP.
- Chromium will boot to a basic status page showing this Device's IP and system configuration. 
- Plymouth will be installed and a simple logo will be displayed during booth with the boot messages scrolling beneath it.
- This script will also set the ubuntu timeouts for DHCP to something reasonable 15 seconds instead of 5 minutes
- This script is idempotent.
- This script can be run in a headless enviroment and will never hang.
- This script will write a detailed log of the steps it takes
- This script will disable all energy saving features to ensure the screen always stays on
- If multiple monitors are attached each one will get its own full screen instance of chromium
- This script will leave a nice easily customizable config file allowing a user to change the boot URL, boot Logo and other paramters
- The script will have all its configurables at the top
