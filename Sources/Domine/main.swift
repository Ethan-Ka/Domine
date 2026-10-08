// Watchdog mode (SPEC 16.11) runs and exits here, before any UI or AppModel exists.
PauseWatchdogProcess.runIfRequested()
DomineApp.main()
