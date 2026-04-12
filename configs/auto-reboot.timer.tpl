[Unit]
Description=Nightly check for pending kernel reboot

[Timer]
OnCalendar=*-*-* __REBOOT_TIME__
Persistent=true

[Install]
WantedBy=timers.target
