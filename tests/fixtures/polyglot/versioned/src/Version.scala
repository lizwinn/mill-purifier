package versioned

@main def version(): Unit = println(s"built with Scala ${BuildInfo.scalaVersion}")
