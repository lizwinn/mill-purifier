import cats.kernel.Monoid

@main def main(): Unit = println(Monoid[Int].combine(1, 2))
