// The root helper. Everything it can do lives in SweepOptimize:
// `HelperMain` starts the Mach service, `CallerVerifier` checks that the
// caller is Sweep, and `PrivilegedTaskRunner` maps a task name to fixed work.
import SweepOptimize

HelperMain.run()
