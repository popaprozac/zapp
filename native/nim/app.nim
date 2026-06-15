## App value + lifecycle. Mirrors the old Zen-C `App` (app.zc): construct it,
## which boots the platform, then `run` enters the Cocoa run loop. Window,
## services and worker wiring land in later tasks.
import platform

type App* = object
  name*: string
  terminateAfterLastWindowClosed*: bool

proc newApp*(name: string, terminateAfterLastWindowClosed = true): App =
  ## Mirrors App::new — init the platform, return the app value.
  platformInit(name)
  App(name: name, terminateAfterLastWindowClosed: terminateAfterLastWindowClosed)

proc run*(app: App): int =
  ## Enters the Cocoa run loop (blocks). Services/workers wired later.
  platformRun(app.terminateAfterLastWindowClosed)
